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
