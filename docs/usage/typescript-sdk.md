---
title: TypeScript SDK
sidebar_position: 4
---

# TypeScript SDK

The SDK wraps the REST and websocket APIs with a lightweight interface. Install it alongside your LLM client of choice.

```bash
npm install fastpaca ai
```

---

## Initialising the client

```typescript
import { createClient } from 'fastpaca';

const fastpaca = createClient({
  baseUrl: process.env.FASTPACA_URL ?? 'http://localhost:4000/v1',
  apiKey: process.env.FASTPACA_API_KEY // optional
});
```

Conversations are identified by your own IDs. The SDK never generates IDs for you.

---

## Core operations

```typescript
const ctx = await fastpaca.context('chat_123')
  .budget(1_000_000)
  .policy({
    strategy: 'last_n',
    config: { limit: 400 }
  });
```

| Method | REST equivalent | Description |
| --- | --- | --- |
| `ctx.append(message, opts?)` | `POST /v1/conversations/:id/messages` | Append a message. Accepts `idempotencyKey`. |
| `ctx.context(opts?)` | `GET /v1/conversations/:id/context` | Fetch the LLM context. Returns `{ messages, usedTokens, needsCompaction, version }`. |
| `ctx.compact(range)` | `POST /v1/conversations/:id/compact` | Replace a sequence range with your own summary messages. |
| `ctx.replay(opts?)` | `GET /v1/conversations/:id/messages` | Async iterator over the message log (supports `fromSeq` / `toSeq`). |
| `ctx.stream(handler, options?)` | Websocket | Stream LLM output back to Fastpaca while sending it to clients. |

Example append:

```typescript
await ctx.append(
  {
    role: 'assistant',
    parts: [
      { type: 'text', text: 'Looking that up now…' },
      { type: 'tool_call', name: 'lookup', payload: { sku: 'A-19' } }
    ]
  },
  { idempotencyKey: 'msg-045' }
);
```

---

## Streaming helper

```typescript
return ctx.stream((messages) =>
  streamText({
    model: openai('gpt-4o-mini'),
    messages
  })
).toResponse();
```

`ctx.stream` will:

1. Fetch the latest LLM context.  
2. Call your handler with that context’s messages.  
3. Relay streamed tokens to the caller.  
4. Append the final assistant message when the stream completes.

Disable the automatic append if you want full control:

```typescript
const stream = await ctx.stream(
  messages => streamText({ model, messages }),
  { autoAppend: false }
);
```

You can then read the stream manually and call `ctx.append` with the final result yourself.

---

## Auto-compaction

Provide an async function to run whenever `needs_compaction` would otherwise be returned:

```typescript
const ctx = await fastpaca.context('chat_123')
  .budget(1_000_000)
  .autoCompact(async context => {
    const head = context.messages.slice(0, -10);
    const summary = await summarize(head);

    return {
      fromSeq: head[0].seq,
      toSeq: head[head.length - 1].seq,
      replacement: [
        { role: 'system', parts: [{ type: 'text', text: summary }] }
      ]
    };
  });
```

Auto-compaction only runs in the process using the SDK. If you scale horizontally you may want to coordinate through the websocket stream instead.

---

## Error handling

- Append conflicts return `409 Conflict` when `ifVersion` guards are used.  
- Network failures during `append` are safe to retry with the same `idempotencyKey`.  
- Streaming helpers surface model errors directly; Fastpaca only appends on successful completion.

See the [REST API reference](../api/rest.md) for full response schemas.
