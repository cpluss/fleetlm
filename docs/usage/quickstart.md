---
title: Quick Start
sidebar_position: 1
---

# Quick Start

Five minutes to a working Fastpaca instance.

---

## 1. Run the server

```bash
docker run -d \
  -p 4000:4000 \
  -v fastpaca_data:/data \
  ghcr.io/fastpaca/fastpaca:latest
```

The API is now available on `http://localhost:4000/v1`.

---

## 2. Create a conversation

```bash
curl -X PUT http://localhost:4000/v1/conversations/demo \
  -H "Content-Type: application/json" \
  -d '{
    "token_budget": 1000000,
    "policy": {
      "strategy": "last_n",
      "config": { "limit": 200 }
    }
  }'
```

---

## 3. Append a message

```bash
curl -X POST http://localhost:4000/v1/conversations/demo/events \
  -H "Content-Type: application/json" \
  -d '{
    "event": {
      "role": "user",
      "parts": [{ "type": "text", "text": "How do I deploy this?" }]
    },
    "idempotency_key": "msg-001"
  }'
```

Response:

```json
{ "seq": 1, "version": 1, "token_estimate": 24 }
```

---

## 4. Fetch the context window

```bash
curl "http://localhost:4000/v1/conversations/demo/window?budget_tokens=1000000"
```

Response (trimmed):

```json
{
  "version": 1,
  "messages": [
    {
      "seq": 1,
      "role": "user",
      "parts": [{ "type": "text", "text": "How do I deploy this?" }]
    }
  ],
  "used_tokens": 24,
  "needs_compaction": false
}
```

---

## 5. Stream an LLM response

```typescript title="app/api/chat/route.ts"
import { fastpaca } from 'fastpaca';
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

export async function POST(req: Request) {
  const { conversationId, message } = await req.json();

  const ctx = await fastpaca.context(conversationId).budget(1_000_000);

  await ctx.append({ role: 'user', content: message });

  return ctx.stream((messages) =>
    streamText({ model: openai('gpt-4o-mini'), messages })
  ).toResponse();
}
```

The helper sends the window to your LLM, streams tokens back to the client, and appends the final assistant message to Fastpaca.

---

## 6. Manually compact when the budget is high

```bash
curl -X POST http://localhost:4000/v1/conversations/demo/compact \
  -H "Content-Type: application/json" \
  -d '{
    "from_seq": 1,
    "to_seq": 1,
    "replacement": [
      {
        "role": "system",
        "parts": [{ "type": "text", "text": "User asked how to deploy Fastpaca." }]
      }
    ]
  }'
```

Fastpaca bumps the conversation version and rewrites the snapshot while preserving the raw log.

---

That’s it. Continue with the [Getting Started](./getting-started.md) guide for more detail, or jump straight to the [API reference](../api/rest.md).
