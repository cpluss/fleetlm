---
title: Clustering Internals
sidebar_position: 1
---

# FleetLM Clustering Guide

This project uses [libcluster](https://hexdocs.pm/libcluster/readme.html) to automatically join nodes together at runtime. The configuration is intentionally minimal so you can run a single node locally while enabling clustering in production by exporting a few environment variables.

## Runtime behaviour

* **Development / Test** – `config/config.exs` sets an empty topology, so no cluster formation happens.
* **Production** – `config/runtime.exs` inspects the following variables at boot. When all checks pass the app starts a `Cluster.Supervisor` that polls DNS records for peers using the `Cluster.Strategy.DNSPoll` strategy.

| Variable | Meaning | Default |
| --- | --- | --- |
| `DNS_CLUSTER_QUERY` | Required. DNS name that resolves to the peer IPs. When unset or blank clustering stays disabled. | _unset_ |
| `DNS_CLUSTER_NODE_BASENAME` | Optional. The node basename to use when generating node names. | `fleetlm` |
| `DNS_POLL_INTERVAL_MS` | Optional. Interval (ms) between DNS lookups. | `5000` |

Each node registers as `"#{DNS_CLUSTER_NODE_BASENAME}@<ip>"`. Fly.io’s Consul-style DNS or Kubernetes headless services work well—point `DNS_CLUSTER_QUERY` at the relevant service name.

## Deployment checklist

1. Ensure your release image/container exports the env vars above (see `docker-compose.yml` for placeholders).
2. Confirm nodes can resolve `DNS_CLUSTER_QUERY` inside the target network.
3. Verify clustering after rollout with `docker exec`/remote shell:

   ```bash
   bin/fleetlm remote "Node.list()"
   ```

   The list should grow as new replicas start.

## Troubleshooting

* **Nodes remain isolated** – check that `DNS_CLUSTER_QUERY` resolves internally and the polling interval is non-zero.
* **Releases crash on boot** – invalid `DNS_POLL_INTERVAL_MS` (non-integer) or misconfigured DNS will surface as boot errors; confirm the environment variable values.
* **Intermittent cluster flapping** – ensure DNS responds quickly or consider lowering `DNS_POLL_INTERVAL_MS` once infrastructure is stable.

## Shard ownership model

FleetLM keeps all hot-path chat traffic off the database by sharding sessions across a pool of transient "slot" processes. Each slot is the single writer for the session ids that hash to it.

The moving parts live under `lib/fleetlm/runtime/sharding/`:

- **`HashRing`** – builds a deterministic consistent hash ring using `:persistent_term`. Configure the slot count and virtual node multiplier via:

  ```elixir
  config :fleetlm, Fleetlm.Runtime.Sharding.HashRing,
    slot_count: 512,
    virtual_nodes_per_node: 128
  ```

- **`Manager`** – watches cluster membership changes (`:net_kernel.monitor_nodes/2`), refreshes the hash ring, synchronises Horde membership, and triggers slot rebalances.
- **`Supervisor`** – a `Horde.DynamicSupervisor` that ensures every slot has a running owner process on the node selected by the ring.
- **`SlotServer`** – the slot owner `GenServer`. It is the single writer for its shard, maintains local caches (future phases), and registers itself in a node-local `Registry` so the gateway can find it quickly.
- **`Slots`** – helper module used by the manager/gateway to lazily start slots and rebalance ownership. Remote operations are performed via `:erpc` so only the relevant node spins up work.
- **`Router`** – the boundary used by Phoenix controllers/channels. It hashes the session id, ensures the slot owner is running (local or remote), and then performs a synchronous call with retries.

### Lifecycle summary

1. Gateway receives a request and calls `Router.append/2`.
2. Router hashes the session id (`HashRing.slot_for_session/1`) and determines the owning node.
3. It asks `Slots.ensure_slot_started/1` locally or via `:erpc` to make sure the `SlotServer` exists.
4. Calls are executed against the node-local registry entry. Retries with exponential backoff handle slot handoffs and process restarts.
5. When the cluster membership changes, `Manager` rebuilds the ring, syncs Horde membership, and invokes `Slots.rebalance_all/0`. Each affected slot drains, shuts down, and Horde restarts it on the new owner node.

### Operational notes

- **Scaling slot count** – increase `slot_count` in the config shown above. Apply the change across the fleet and restart nodes in small batches. `HashRing.refresh!/0` ensures every node rebuilds the same mapping.
- **Observability** – Telemetry counters continue to track append latency; slot queue depth metrics now reflect the per-slot (single-writer) mailbox length.
- **Manual rebalances** – you can trigger a targeted drain from a remote shell:

  ```elixir
  # drain slot 42 immediately
  Fleetlm.Runtime.Sharding.SlotServer.rebalance(42)

  # force a full rebalance against the current ring
  Fleetlm.Runtime.Sharding.Slots.rebalance_all()
  ```

- **Testing locally** – the sharding system works on a single node without starting distributed Erlang. The local registry keeps lookups cheap, while `:erpc` remains a no-op when the owning node is `Node.self()`.

- **Cleanup between tests** – the test helper (`Fleetlm.Runtime.TestHelper.reset/0`) now tears down any running slot owners so integration tests start from a clean slate.
