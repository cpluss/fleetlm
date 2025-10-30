---
title: Deployment
sidebar_position: 3
---

# Deployment

Fastpaca is built to run in your own infrastructure. This page covers recommended runtimes, storage, and operational knobs.

---

## Hardware & storage

- **CPU:** 2+ vCPUs per node (Raft + token accounting are CPU-bound).  
- **Memory:** 4 GB RAM per node for typical workloads. Increase if you retain very large snapshots.  
- **Disk:** Fast SSD/NVMe for the Raft log (append-heavy). Mount `/data` on dedicated storage.  
- Set `FASTPACA_RAFT_DATA_DIR` to the mounted volume path so Raft logs survive restarts.  
- **Network:** Low-latency links between nodes. For production, keep Raft replicas within the same AZ or region (&lt;5 ms RTT).

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

Repeat with `FASTPACA_NODE_NAME=fastpaca-2/3`. Nodes automatically discover peers through the seed list and form a Raft cluster.

### Placement guidelines

- Run exactly three replicas for quorum (tolerates one node failure).  
- Pin each replica to separate AZs only if network RTT remains low.  
- Use Kubernetes StatefulSets, Nomad groups, or bare metal with systemd; the binary is self-contained.

---

## Optional archival (Postgres)

Fastpaca does not require external storage for correctness. Configure an archive if you need:

- Long‑term history beyond the Raft tail.  
- Analytics / BI queries on the full log.  
- Faster cold‑start recovery for very old contexts.

The Postgres archiver is built‑in. It persists messages and then acknowledges a high‑water mark to Raft so the tail can trim older segments while retaining a safety buffer.

Archiver environment variables (auto‑migrations on boot when enabled):

```bash
-e FASTPACA_ARCHIVER_ENABLED=true \
-e DATABASE_URL=postgres://user:password@host/db \
-e FASTPACA_ARCHIVE_FLUSH_INTERVAL_MS=5000 \
-e FASTPACA_ARCHIVER_BATCH_SIZE=5000 \
-e MIGRATE_ON_BOOT=true
```

Tail retention (active now):

```bash
-e FASTPACA_TAIL_KEEP=1000   # messages retained in Raft tail (minimum); Raft never evicts messages newer than the archived watermark
```

See Storage & Audit for schema and audit details: ./storage.md

---

## Metrics & observability

Prometheus metrics are exposed on `/metrics`.  Key series:

- `fastpaca_messages_append_total` – total messages appended (by role/source)
- `fastpaca_messages_token_count` – token count per appended message (distribution)
- `fastpaca_archive_pending_rows` – rows pending in the archive queue (ETS)
- `fastpaca_archive_pending_contexts` – contexts pending in the archive queue
- `fastpaca_archive_flush_duration_ms` – flush tick duration
- `fastpaca_archive_attempted_total` / `fastpaca_archive_inserted_total` – rows attempted/inserted
- `fastpaca_archive_lag` – per-context lag (last_seq - archived_seq)
- `fastpaca_archive_tail_size` – Raft tail size after trim (per context)
- `fastpaca_archive_trimmed_total` – entries trimmed from Raft tail
- `fastpaca_archive_llm_token_count` – LLM window token count (per context)

Logs follow JSON structure with fields like `type`, `context_id`, and `seq`. Forward them to your logging stack for audit trails.

---

## Backups & retention

- Raft log and snapshots reside in `/data`.  Snapshot the volume regularly (EBS/GCE disk snapshots).  
- If Postgres is enabled, use standard database backups.  
- Periodically export contexts for legal or compliance requirements via the `/v1/contexts/:id/messages` endpoint.

---

## Scaling out

- **More throughput:** Add additional nodes; Raft group assignment is deterministic and redistributed automatically via coordinator pattern (lowest node ID manages topology).
- **Sharding:** Not required for most workloads — 256 Raft groups provide sufficient horizontal fan-out.
- **Read replicas:** Not needed; every node can serve reads. Use Postgres replicas if you run heavy analytics.
- **Coordinator failover:** If the coordinator node fails, the next-lowest node automatically becomes coordinator. No manual intervention required.


---

## Configuration summary

| Variable | Default | Description |
| --- | --- | --- |
| `FASTPACA_NODE_NAME` | Random UUID | Human-readable node identifier (shows up in logs/metrics) |
| `FASTPACA_CLUSTER_SEED` | None | Comma-separated list of peer hosts (`host:port`). Required for multi-node. |
| `FASTPACA_RAFT_DATA_DIR` | `priv/raft` | Filesystem path for Raft logs and snapshots (mount durable storage here). |
| `FASTPACA_TOKEN_ESTIMATOR` | `tiktoken:gpt-4o` | Token estimator to use for budget tracking. |
| `FASTPACA_STREAM_MAX_CONNECTIONS` | 512 | Per-node websocket limit. |
| `FASTPACA_API_KEY` | None | Optional bearer token for REST/Websocket auth. |

Consult the sample configuration file in the repository for all options.
