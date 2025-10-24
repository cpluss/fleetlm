---
title: Architecture
sidebar_position: 4
---

# Architecture

Fastpaca runs a Raft-backed state machine that keeps the conversation log, snapshot, and LLM context builder in one place. Every node exposes the same API; requests can land anywhere and are routed to the appropriate shard.

![Fastpaca Architecture](./img/architecture.png)

## Components

| Component | Responsibility |
| --- | --- |
| **REST / Websocket gateway** | Validates requests and forwards them to the runtime. |
| **Runtime** | Applies appends, builds LLM context, enforces token budgets, and triggers compaction flags. |
| **Raft groups** | 256 logical shards, each replicated across three nodes.  Provide ordered, durable writes. |
| **Snapshot manager** | Maintains compacted summaries alongside the raw log. |
| **Flusher (optional)** | Streams committed messages to Postgres for analytics/archival. |

## Data flow

1. **Append** – the node forwards the message to the shard leader; once a quorum commits, the snapshot updates and the client receives `{seq, version}`.  
2. **Window** – the node reads the snapshot from memory, trims it to the requested budget, and returns messages + metadata.  
3. **Compact** – the node rewrites the snapshot range atomically and bumps the conversation version; the raw log remains untouched.  
4. **Stream/Replay** – served directly from the in-memory snapshot and ETS tail, falling back to Postgres or the Raft log when needed.

## Operational notes

- Leader election is automatic.  Losing one node leaves the cluster writable (2/3 quorum).  
- Append latency is dominated by network RTT between replicas; keep nodes close.  
- Snapshots are persisted as part of Raft checkpoints so a node can recover its state without replaying the entire log.  
- The architecture is symmetric — there is no special coordinator or control plane to manage.
