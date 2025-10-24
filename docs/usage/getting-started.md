---
title: Getting Started
sidebar_position: 2
---

# Getting Started

This guide expands on the quick start and explains how the pieces fit together: conversations, events, windows, compaction, and streaming.

---

## Conversation lifecycle

Each conversation you create has three important views:

1. **Append log** – the ordered sequence of events stored in Raft.  
2. **Snapshot** – a compacted summary plus the recent tail, maintained automatically.  
3. **Context window** – the token-budgeted slice returned by `/window`.

Creating a conversation sets the token budget and compaction policy:

```bash
curl -X PUT http://localhost:4000/v1/conversations/support-123 \
  -H "Content-Type: application/json" \
  -d '{
    "token_budget": 1000000,
    "policy": {
      "strategy": "last_n",
      "config": { "limit": 400 }
    }
  }'
```

Policies are described in [Context Management](./context-management.md).

---

## Appending events

Events are immutable. Fastpaca assigns `seq` and `version` once a quorum of replicas has committed the write.

```bash
curl -X POST http://localhost:4000/v1/conversations/support-123/events \
  -H "Content-Type: application/json" \
  -d '{
    "event": {
      "role": "assistant",
      "parts": [
        { "type": "text", "text": "I can help with that." },
        { "type": "tool_call", "name": "lookup_manual", "payload": { "article": "installing" } }
      ],
      "metadata": { "reasoning": "User asked for deployment steps." }
    },
    "idempotency_key": "msg-017"
  }'
```

If the request fails mid-flight you can retry with the same `idempotency_key` — Fastpaca will ignore duplicates.

---

## Fetching the context window

```bash
curl "http://localhost:4000/v1/conversations/support-123/window?budget_tokens=1000000"
```

Response:

```json
{
  "version": 42,
  "messages": [...],
  "used_tokens": 702134,
  "needs_compaction": true,
  "segments": [
    { "type": "summary", "from_seq": 1, "to_seq": 20 },
    { "type": "live", "from_seq": 21, "to_seq": 42 }
  ]
}
```

`needs_compaction` flips to `true` when Fastpaca estimates that the next append or window would push the transcript beyond 70% of the configured budget. Use this as a trigger for your own summarisation or trimming logic.

---

## Compacting history

Compaction rewrites part of the snapshot while leaving the raw log untouched. Pick the range and provide replacement events.

```bash
curl -X POST http://localhost:4000/v1/conversations/support-123/compact \
  -H "Content-Type: application/json" \
  -d '{
    "from_seq": 1,
    "to_seq": 20,
    "replacement": [
      {
        "role": "system",
        "parts": [
          {
            "type": "text",
            "text": "Summary of earlier troubleshooting steps..."
          }
        ]
      }
    ]
  }'
```

Fastpaca increments the `version`, recalculates the snapshot, and the next window returns the summary followed by the untouched tail.

---

## Streaming changes

Backends can subscribe to a conversation to push updates downstream or trigger background work:

```bash
wscat -c "ws://localhost:4000/v1/conversations/support-123/stream?cursor=40"
```

Sample messages:

```json
{ "type": "event", "seq": 41, "version": 41 }
{ "type": "window", "version": 41 }
{ "type": "compaction", "version": 42 }
```

Reconnect with the latest version to resume without gaps. The protocol is detailed in the [Websocket reference](../api/websocket.md).

---

## Next steps

- Implement your compaction policy: [Context Management](./context-management.md)  
- Call the API from code: [TypeScript SDK](./typescript-sdk.md)  
- See end-to-end samples: [Examples](./examples.md)
