---
title: Deployment
sidebar_position: 3
---

# Deployment

Fastpaca is built to run in your own infrastructure.  This page covers recommended runtimes, storage, and operational knobs.

---

## Hardware & storage

- **CPU:** 2+ vCPUs per node (Raft + token accounting are CPU-bound).  
- **Memory:** 4 GB RAM per node for typical workloads.  Increase if you retain very large snapshots.  
- **Disk:** Fast SSD/NVMe for the Raft log (append-heavy).  Mount `/data` on dedicated storage.  
- **Network:** Low-latency links between nodes.  For production, keep Raft replicas within the same AZ or region (&lt;5 ms RTT).

---

## Single-node development

```bash
docker run -d \
  -p 4000:4000 \
  -v fastpaca_data:/data \
  ghcr.io/fastpaca/fastpaca:latest
```

The node serves REST on `:4000`, websockets on the same port, and Prometheus metrics on `/metrics`.

Data persists across restarts as long as the `fastpaca_data` volume remains.

---

## Three-node production cluster

Create a DNS entry (or static host list) that resolves to all nodes, e.g. `fastpaca.internal`.

On each node:

```bash
docker run -d \
  -p 4000:4000 \
  -v /var/lib/fastpaca:/data \
  -e FASTPACA_CLUSTER_SEED=fastpaca.internal:4000 \
  -e FASTPACA_NODE_NAME=fastpaca-1 \
  ghcr.io/fastpaca/fastpaca:latest
```

Repeat with `FASTPACA_NODE_NAME=fastpaca-2/3`.  Nodes automatically discover peers through the seed list and form a Raft cluster.

### Placement guidelines

- Run exactly three replicas for quorum (tolerates one node failure).  
- Pin each replica to separate AZs only if network RTT remains low.  
- Use Kubernetes StatefulSets, Nomad groups, or bare metal with systemd — the binary is self-contained.

---

## Optional Postgres write-behind

Fastpaca does not require Postgres for correctness.  Configure it if you need:

- Long-term archival beyond the Raft snapshot retention window.  
- Analytics / BI queries on the full log.  
- Faster cold-start recovery for very old conversations.

Set environment variables:

```bash
-e FASTPACA_POSTGRES_URL=postgres://user:password@host/db
-e FASTPACA_POSTGRES_POOL_SIZE=20
-e FASTPACA_FLUSH_INTERVAL_MS=5000
-e FASTPACA_FLUSH_BATCH_SIZE=5000
```

The flusher retries on failure and does not block the hot path.

---

## Metrics & observability

Prometheus metrics are exposed on `/metrics`.  Key series:

- `fastpaca_append_latency_ms` (p50/p95)  
- `fastpaca_window_latency_ms`  
- `fastpaca_snapshot_token_count` (per conversation)  
- `fastpaca_compaction_requests_total`  
- `fastpaca_raft_pending_flush_messages`

Logs follow JSON structure with `event`, `conversation_id`, and `seq`.  Forward them to your logging stack for audit trails.

---

## Backups & retention

- Raft log and snapshots reside in `/data`.  Snapshot the volume regularly (EBS/GCE disk snapshots).  
- If Postgres is enabled, use standard database backups.  
- Periodically export conversations for legal or compliance requirements via the `/events` endpoint.

---

## Scaling out

- **More throughput:** Add additional nodes; Raft group assignment is deterministic and redistributed automatically.  
- **Sharding:** Not required for most workloads — 256 Raft groups provide sufficient horizontal fan-out.  
- **Read replicas:** Not needed; every node can serve reads.  Use Postgres replicas if you run heavy analytics.

---

## Configuration summary

| Variable | Default | Description |
| --- | --- | --- |
| `FASTPACA_NODE_NAME` | Random UUID | Human-readable node identifier (shows up in logs/metrics) |
| `FASTPACA_CLUSTER_SEED` | None | Comma-separated list of peer hosts (`host:port`). Required for multi-node. |
| `FASTPACA_TOKEN_ESTIMATOR` | `tiktoken:gpt-4o` | Token estimator to use for budget tracking. |
| `FASTPACA_STREAM_MAX_CONNECTIONS` | 512 | Per-node websocket limit. |
| `FASTPACA_API_KEY` | None | Optional bearer token for REST/Websocket auth. |

Consult the sample configuration file in the repository for all options.
