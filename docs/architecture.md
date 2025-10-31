---
title: Architecture
sidebar_position: 4
---

# Architecture

Fastpaca Context Store runs a Raft-backed state machine that keeps the context log, snapshot, and LLM context builder in one place. Every node exposes the same API; requests can land anywhere and are routed to the appropriate shard.

![Fastpaca Context Store Architecture](./img/architecture.png)

## Components

| Component | Responsibility |
| --- | --- |
| **REST / Websocket gateway** | Validates requests and forwards them to the runtime. |
| **Runtime** | Applies appends, builds LLM context, enforces token budgets, and triggers compaction flags. |
| **Raft groups** | 256 logical shards, each replicated across three nodes.  Provide ordered, durable writes. |
| **Snapshot manager** | Maintains compacted summaries alongside the raw log. |
| **Archiver (optional)** | Writes committed messages to cold storage (Postgres/S3). Leader-only, fed by Raft effects. |

## Data flow

1. **Append** – the node forwards the message to the shard leader; once a quorum commits, the Context updates (LLM window + tail) and the client receives `{seq, version}`.
2. **Window** – the node reads the LLM window from memory, applies the current policy, and returns messages + metadata.
3. **Compact** – the node rewrites the LLM window atomically and bumps the context version; the tail is unchanged.
4. **Archive (optional)** – the leader-only Archiver persists messages to cold storage (Postgres/S3) and then acknowledges a high-water mark (`ack_archived(seq)`), allowing Raft to trim older tail segments while retaining a small bounded tail.
5. **Stream/Replay** – served directly from the in-memory tail; future versions may page older history from cold storage when offset exceeds the tail.

## Storage Tiers

- **Hot (Raft):**
  - LLM context window (bounded via policy)
  - Message tail (bounded ring with invariant: never evict messages newer than the archived watermark)
  - Watermarks: `last_seq` (writer), `archived_seq` (trim cursor)
- **Cold (Archive):**
  - Full message history in Postgres/S3 (optional component, added in a follow-up)

## Operational notes

- Leader election is automatic. Losing one node leaves the cluster writable (2/3 quorum).
- Append latency is dominated by network RTT between replicas; keep nodes close.
- Snapshots are small: they include the LLM window, bounded tail, and watermarks. ETS or archiver buffers are not part of snapshots.
- **Topology coordinator**: The lowest node ID (by sort order) manages Raft group membership. Coordinator bootstraps new groups and rebalances replicas when nodes join/leave. Non-coordinators join existing groups and keep local replicas running. If coordinator fails, the next-lowest node automatically takes over.
