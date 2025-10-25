---
title: Quick Start
sidebar_position: 1
---

# Quick Start

## 1. Run Fastpaca

```bash
docker run -d \
  -p 4000:4000 \
  -v fastpaca_data:/data \
  ghcr.io/fastpaca/fastpaca:latest
```

Fastpaca now listens on `http://localhost:4000/v1`. The container persists data under `fastpaca_data/`.

---

## 2. Create a context

Create a context with the id `demo-chat`.

```bash
curl -X PUT http://localhost:4000/v1/contexts/demo-chat \
  -H "Content-Type: application/json" \
  -d '{
    "token_budget": 1000000,
    "trigger_ratio": 0.7,
    "policy": {
      "strategy": "last_n",
      "config": { "limit": 200 }
    }
  }'
```

---

## 3. Append a message

Adds a user message with `How do I deploy this?` as text.

```bash
curl -X POST http://localhost:4000/v1/contexts/demo-chat/messages \
  -H "Content-Type: application/json" \
  -d '{
    "message": {
      "role": "user",
      "parts": [{ "type": "text", "text": "How do I deploy this?" }]
    },
    "idempotency_key": "msg-001"
  }'
```

Fastpaca replies with the assigned sequence number and version:

```json
{ "seq": 1, "version": 1, "token_estimate": 24 }
```

Retry with the same `idempotency_key` if the network flakes; duplicates are ignored.

---

## 4. Get the LLM context

The context endpoint returns the current LLM context plus metadata.

```bash
curl http://localhost:4000/v1/contexts/demo-chat/context
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

Feed `messages` directly into your LLM client.

---

## 5. Stream a response (Next.js + ai-sdk)

Plug and play with ai-sdk by default in typescript!

```typescript title="app/api/chat/route.ts"
import { fastpaca } from 'fastpaca';
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

export async function POST(req: Request) {
  const { contextId, message } = await req.json();

  const ctx = await fastpaca.context(contextId).budget(1_000_000);

  await ctx.append({
    role: 'user',
    parts: [{ type: 'text', text: message }]
  });

  return ctx.stream(messages =>
    streamText({ model: openai('gpt-4o-mini'), messages })
  ).toResponse();
}
```

---

Ready to go deeper? Continue with [Getting Started](./getting-started.md) or jump straight to the [API reference](../api/rest.md).
