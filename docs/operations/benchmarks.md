---
sidebar_position: 2
---

# Benchmarks

> **Latest highlight:** 7.5k msg/s sustained on a 3-node cluster (c7g.2xlarge + Aurora PostgreSQL) with p99 latency under 150 ms.

## Current Results

| Date | Commit | Setup | Throughput | p99 Latency | Notes |
|------|--------|-------|------------|-------------|-------|
| 2025-10-17 | `650292e` | 3 nodes, c7g.2xlarge (per node) + Aurora PostgreSQL | **7.5k msg/s** sustained | 148 ms | Raft quorum writes, AI SDK streaming, production-sized fleet |
| 2025-06-03 | `1f2d8b7` | 1 node, c5d.large + RDS db.t3.small | ~800 msg/s | 62 ms | Local NVMe WAL, durability-first baseline |

## Methodology

**What we measure:** Durable message throughput with real fsync guarantees. Every ack means the message is persisted.

### Infrastructure

- **3-node cluster test (production profile):**
  - FleetLM nodes: AWS EC2 c7g.2xlarge (8 vCPU Graviton, 16 GB RAM) with gp3 SSD
  - Database: Amazon Aurora PostgreSQL (db.r6g.large, 2 replicas)
  - Traffic generator: k6 (m6i.large) in the same VPC
- **Single-node baseline:**
  - FleetLM node: AWS EC2 c5d.large (2 vCPU, 4 GB RAM, 50 GB NVMe instance store)
  - Database: AWS RDS db.t3.small (Postgres 15)
  - Traffic generator: k6 (t3.medium) in the same VPC
- **Mock agent:** lightweight HTTP responder that streams AI SDK chunks without LLM latency
- **Client protocol:** WebSocket streaming plus periodic REST replays to exercise both paths

All infrastructure defined in reproducible Terraform configuration.

### Durability Guarantees

FleetLM prioritizes **durability and predictability** over raw throughput:

- **Durable writes**: Every message ack guarantees fsync to NVMe storage
- **No data loss**: Messages survive process crashes and restarts
- **Bounded latency**: Timeouts prevent unbounded queueing
- **Batch persistence**: WAL flushes to Postgres every 300ms in background

This is a **durable conversation store with strong guarantees**, not an in-memory message queue.

### Test Configuration

- **3-node cluster:** 300 concurrent virtual users, pipeline depth 5, test length 5 minutes after 60 second ramp
- **Single-node baseline:** 30 concurrent virtual users, pipeline depth 5, test length 1 minute after 30 second ramp

## Interpretation

**7.5k msg/s sustained throughput** across three Raft replicas shows that redundancy does not require giving up performance:

- Every message is fsync’d to a quorum (2 of 3 nodes) before the ack leaves FleetLM.
- Latency stays under 150 ms at p99 even with catch-up workers streaming AI SDK chunks.
- CPU averaged 58% per node with room for vertical growth; network and Raft coordination dominated utilisation.
- Aurora replay lag stayed < 200 ms, so cold reads and analytics keep pace with the log.

**~800 msg/s on a single c5d.large** remains a useful baseline for local durability:

- NVMe-backed WAL keeps write latency predictable even on modest hardware.
- CPU at 40% shows the runtime is IO-bound rather than scheduler bound.
- Memory remained flat (~130 MB) over the test window.

The key takeaway: FleetLM scales horizontally with predictable latency, and even the entry-level setup provides durable guarantees far beyond an in-memory queue.

## How to Reproduce

See [bench/aws](https://github.com/cpluss/fleetlm/tree/main/bench/aws) for full setup.
