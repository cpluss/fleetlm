---
title: Storage & Audit
sidebar_position: 2
---

# Storage & Audit

Fastpaca separates hot runtime storage (Raft) from optional cold storage used for long‑term history and audit. This page covers what is stored where, how retention works, and how to enable an audit‑grade archive.

---

## Storage tiers

- Hot (Raft)
  - LLM context window (bounded by policy)
  - Message tail (bounded ring; invariant: never evict messages newer than the archived watermark)
  - Watermarks: `last_seq` (writer position), `archived_seq` (trim cursor)
- Cold (Archive)
  - Full message history per context for analytics, compliance, and replay beyond the in‑memory tail
  - Implemented adapter: Postgres
  - Planned adapter: S3 (JSONL objects with idempotent writes)

Raft snapshots include the window, a bounded tail, and watermarks. Cold storage holds the full immutable history. The runtime acknowledges cold‑store progress via `ack_archived(seq)` which allows trimming older portions of the tail while keeping a safety buffer (`tail_keep`).

---

## Audit goals and guarantees

- Append‑only history keyed by `(context_id, seq)` with a total order per context.
- Idempotent archival: duplicates are ignored (`ON CONFLICT DO NOTHING`).
- Messages are immutable; compaction only rewrites the LLM input window, not the raw message log.
- At‑least‑once delivery from runtime to archive with batch retries and back‑pressure signaling via telemetry.

For legal/compliance export, query the archive by `context_id` ordered by `seq`, or page the live tail for recent history if you have not enabled an archive.

---

## Enabling the Postgres archive

The Postgres adapter is built‑in and disabled by default. Enable it via env and provide a database URL. On boot, Fastpaca will run migrations automatically (idempotent) when the archiver is enabled.

```bash
-e FASTPACA_ARCHIVER_ENABLED=true \
-e DATABASE_URL=postgres://user:password@host:5432/db \
-e FASTPACA_ARCHIVE_FLUSH_INTERVAL_MS=5000 \
-e FASTPACA_ARCHIVER_BATCH_SIZE=5000 \
-e MIGRATE_ON_BOOT=true
```

Details
- Auto‑migrations create the `messages` table with a composite primary key `(context_id, seq)` and an index on `(context_id, inserted_at)`.
- Inserts are chunked and idempotent. The adapter uses `ON CONFLICT DO NOTHING` so replays are safe.
- The runtime computes a contiguous `upto_seq` watermark for each flush; once acknowledged, older tail segments may be trimmed while retaining `FASTPACA_TAIL_KEEP` messages.

---

## Retention and trimming

- Configure tail retention with `FASTPACA_TAIL_KEEP` (default `1000`).
- The runtime never trims messages newer than `archived_seq`.
- If archiving is disabled, all messages remain in the Raft tail until they exceed in‑memory bounds; use the tail API to export regularly for compliance.

---

## S3 archive (planned)

An S3 adapter is planned for clusters that prefer object storage. Recommended layout (for planning/migration):

```
s3://<bucket>/contexts/<context_id_hash>/<context_id>/<yyyy>/<mm>/<dd>.jsonl
```

Each line: `{context_id, seq, role, parts, metadata, token_count, inserted_at}`. Objects are appended via idempotent writes; ordering within a day file is by `seq`.

---

## Telemetry and monitoring

Key Prometheus series exposed via `/metrics` (subset):

- `fastpaca_archive_pending_rows` / `fastpaca_archive_pending_contexts`
- `fastpaca_archive_attempted_total` / `fastpaca_archive_inserted_total`
- `fastpaca_archive_bytes_attempted_total` / `fastpaca_archive_bytes_inserted_total`
- `fastpaca_archive_flush_duration_ms`
- `fastpaca_archive_lag` (per context)
- `fastpaca_archive_tail_size` and `fastpaca_archive_trimmed_total`

Use logs as a secondary audit trail. Structured logs include fields like `type`, `context_id`, and `seq` suitable for ingestion by your logging stack.

---

## Exporting history

- With Postgres: `SELECT * FROM messages WHERE context_id = $1 ORDER BY seq;`
- Without archive: iterate the live tail via `GET /v1/contexts/:id/tail?offset=…&limit=…` until empty and persist externally.

For large contexts, prefer server‑side exports from your data store and page by `seq`.
