---
title: REST API
sidebar_position: 1
---

# REST API

All endpoints live under `/v1`.  Requests must include `Content-Type: application/json` where applicable.  Responses are JSON unless stated otherwise.

## Contexts

### PUT `/v1/contexts/:id`

Create or update a context. Idempotent (`PUT`).

```json title="Request body"
{
  "token_budget": 1000000,
  "policy": {
    "strategy": "last_n",
    "config": { "limit": 400, "trigger_ratio": 0.7 }
  },
  "metadata": {
    "project": "support"
  }
}
```

```json title="Response"
{
  "id": "support-123",
  "token_budget": 1000000,
  "policy": { ... },
  "version": 0,
  "created_at": "2025-01-24T12:00:00Z",
  "updated_at": "2025-01-24T12:00:00Z"
}
```

`trigger_ratio` defaults to `0.7` if omitted.

### GET `/v1/contexts/:id`

Returns the current context configuration and metadata.

### DELETE `/v1/contexts/:id`

Tombstones the context. Existing messages remain available for replay, but new messages are rejected.

## Messages

### POST `/v1/contexts/:id/messages`

Append a message.

```json title="Request body"
{
  "message": {
    "role": "assistant",
    "parts": [
      { "type": "text", "text": "Checking now…" },
      { "type": "tool_call", "name": "lookup", "payload": { "sku": "A-19" } }
    ],
    "metadata": { "reasoning": "User asked for availability." }
  },
  "idempotency_key": "msg-045",
  "if_version": 41
}
```

```json title="Response"
{ "seq": 42, "version": 42, "token_estimate": 128 }
```

- `idempotency_key` is optional but recommended for retries.  
- `if_version` enforces optimistic concurrency. The server returns `409 Conflict` if the current version does not match.

### GET `/v1/contexts/:id/messages`

Page through the message log. Supports `from_seq`/`to_seq`, `cursor`/`limit`, and negative offsets.

```
GET /v1/contexts/demo/messages?from_seq=101&to_seq=120
GET /v1/contexts/demo/messages?cursor=200&limit=50
GET /v1/contexts/demo/messages?from_seq=-100          # last 100 messages
```

Response:

```json
{
  "messages": [
    {
      "seq": 101,
      "role": "user",
      "parts": [{ "type": "text", "text": "…" }],
      "inserted_at": "2025-01-24T12:00:00Z"
    }
  ],
  "next_cursor": 200
}
```

Use `next_cursor` to continue paging or resume after a disconnect.

## LLM context

### GET `/v1/contexts/:id/context`

Returns the current LLM context (the slice you send to your LLM).

Query parameters:

- `budget_tokens` (optional) – temporarily override the configured budget.  
- `if_version` (optional) – fail with `409` if the snapshot changed since the supplied version.

```json title="Response"
{
  "version": 84,
  "messages": [...],
  "used_tokens": 702134,
  "needs_compaction": true,
  "segments": [
    { "type": "summary", "from_seq": 1, "to_seq": 340 },
    { "type": "live", "from_seq": 341, "to_seq": 384 }
  ]
}
```

## Compaction

### POST `/v1/contexts/:id/compact`

Rewrite part of the snapshot.  The raw log remains untouched for replay/audit.

```json title="Request body"
{
  "from_seq": 1,
  "to_seq": 340,
  "replacement": [
    {
      "role": "system",
      "parts": [
        { "type": "text", "text": "Summary covering seq 1-340…" }
      ]
    }
  ],
  "if_version": 83
}
```

```json title="Response"
{ "version": 84 }
```

If the server detects gaps or overlapping ranges it returns `400 Bad Request`.

## Context metadata

### PATCH `/v1/contexts/:id/metadata`

Upsert custom metadata associated with the context.  Metadata is stored alongside the snapshot and returned by `GET /v1/contexts/:id`.

```json
{ "metadata": { "customer": "acme-corp", "priority": "gold" } }
```

## Health endpoints

- `GET /health/live` – returns `{"status":"ok"}` when the node is accepting traffic.  
- `GET /health/ready` – returns `{"status":"ok"}` when the node has joined the cluster and can serve requests.

---

## Error codes

| Status | Meaning | Notes |
| --- | --- | --- |
| `400` | Invalid payload | Schema or validation failure |
| `401` | Unauthorized | Missing/invalid API key (when enabled) |
| `404` | Not found | Context does not exist |
| `409` | Conflict | Version guard failed or context tombstoned |
| `429` | Rate limited | Per-node rate limiting (configurable) |
| `500` | Internal error | Unexpected server failure |
| `503` | Unavailable | No Raft quorum available (retry with backoff) |

Errors follow a consistent shape:

```json
{
  "error": "conflict",
  "message": "Context version changed (expected 83, found 84)"
}
```
