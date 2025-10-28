---
title: REST API
sidebar_position: 1
---

# REST API

All endpoints live under `/v1`. Requests must include `Content-Type: application/json` where applicable. Responses are JSON unless stated otherwise.

## Contexts

### PUT `/v1/contexts/:id`

Create or update a context. Idempotent (`PUT`).

```json title="Request body"
{
  "token_budget": 1000000,
  "trigger_ratio": 0.7,
  "policy": {
    "strategy": "last_n",
    "config": { "limit": 400 }
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
    "token_count": 128,
    "metadata": { "reasoning": "User asked for availability." }
  },
  "if_version": 41
}
```

```json title="Response"
{ "seq": 42, "version": 42, "token_estimate": 128 }
```

- `token_count` (optional): when provided, the server uses it verbatim. If omitted, the server computes an approximate value.
- `if_version` (optional): Enforces optimistic concurrency control. The server returns `409 Conflict` if the current context version does not match the supplied value. Use this to prevent race conditions when multiple clients append simultaneously.

### GET `/v1/contexts/:id/tail`

Retrieve messages with tail-based pagination (newest to oldest). Designed for backward iteration from recent messages, ideal for infinite scroll, mobile apps, and future tiered storage.

Query parameters:
- `limit` (integer, default: 100): maximum messages to return
- `offset` (integer, default: 0): number of messages to skip from tail (0 = most recent)

```bash
# Get last 50 messages
GET /v1/contexts/demo/tail?limit=50

# Get next page (messages 51-100 from tail)
GET /v1/contexts/demo/tail?offset=50&limit=50

# Get third page (messages 101-150 from tail)
GET /v1/contexts/demo/tail?offset=100&limit=50
```

Response:

```json
{
  "messages": [
    {
      "seq": 951,
      "role": "user",
      "parts": [{ "type": "text", "text": "…" }],
      "token_count": 42,
      "metadata": {},
      "inserted_at": "2025-01-24T12:00:00Z"
    },
    {
      "seq": 952,
      "role": "assistant",
      "parts": [{ "type": "text", "text": "…" }],
      "token_count": 128,
      "metadata": {},
      "inserted_at": "2025-01-24T12:00:15Z"
    }
  ]
}
```

Messages are returned in **chronological order** (oldest to newest in the result). An empty array indicates you've reached the beginning of history.

**Pagination pattern:**
```typescript
let offset = 0;
const limit = 100;

while (true) {
  const { messages } = await fetch(
    `/v1/contexts/${id}/tail?offset=${offset}&limit=${limit}`
  ).then(r => r.json());

  if (messages.length === 0) break; // Reached beginning

  displayMessages(messages);
  offset += messages.length;
}
```

## LLM context

### GET `/v1/contexts/:id/context`

Returns the current LLM context (the slice you send to your LLM).

Query parameters:

- `budget_tokens` (optional): temporarily override the configured budget.  
- `if_version` (optional): fail with `409` if the snapshot changed since the supplied version.

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

Rewrite the LLM context snapshot in full. The raw message log remains untouched for replay/audit. This is an all-or-nothing replacement of the current LLM window.

```json title="Request body"
{
  "replacement": [
    {
      "role": "system",
      "parts": [
        { "type": "text", "text": "One-paragraph summary of prior context…" }
      ]
    },
    { "role": "user", "parts": [{ "type": "text", "text": "The most recent question." }] }
  ],
  "if_version": 83
}
```

```json title="Response"
{ "version": 84 }
```

Partial ranges are not supported. To preserve a tail, include those messages in `replacement`.

## Context metadata

### PATCH `/v1/contexts/:id/metadata`

Upsert custom metadata associated with the context. Metadata is stored alongside the snapshot and returned by `GET /v1/contexts/:id`.

```json
{ "metadata": { "customer": "acme-corp", "priority": "gold" } }
```

## Health endpoints

- `GET /health/live` - returns `{"status":"ok"}` when the node is accepting traffic.  
- `GET /health/ready` - returns `{"status":"ok"}` when the node has joined the cluster and can serve requests.

---

## Error codes

| Status | Meaning | Notes |
| --- | --- | --- |
| `400` | Invalid payload | Schema or validation failure |
| `401` | Unauthorized | Missing/invalid API key (when enabled) |
| `404` | Not found | Context does not exist |
| `409` | Conflict | Version guard failed (`if_version` mismatch) or context tombstoned |
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

### Handling version conflicts (409)

When `if_version` is supplied, the server checks the current context version before appending. A `409 Conflict` response indicates the version has changed since your last read.

**Retry pattern for network failures:**
1. Read current context version (from `GET /contexts/:id` or append response)
2. Append with `if_version` matching the current version
3. On timeout or 5xx errors, retry the same request (version unchanged)
4. On `409 Conflict`, read the context again to get the updated version, then retry with the new version

This provides optimistic concurrency control without requiring per-message idempotency keys.
