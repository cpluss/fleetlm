---
title: TypeScript SDK
sidebar_position: 4
---

# TypeScript SDK

These helpers mirror the REST API shown in the Quick Start / Getting Started guides. They expect ai-sdk style messages (`UIMessage`) and keep the same method names you’ve already seen there.

```bash
npm install fastpaca
```

## 1. Create (or load) a context

```typescript
import { createClient } from 'fastpaca';

const fastpaca = createClient({
  baseUrl: process.env.FASTPACA_URL ?? 'http://localhost:4000/v1',
  apiKey: process.env.FASTPACA_API_KEY // optional
});

// Idempotent create/update when options are provided
const ctx = await fastpaca.context('123456', {
  budget: 1_000_000,              // token budget for this context
  trigger: 0.7,                   // optional trigger ratio (defaults to 0.7)
  policy: { strategy: 'last_n', config: { limit: 400 } }
});
```

`context(id)` never creates IDs for you—you decide what to use so you can continue the same context later.

## 2. Append messages (ai-sdk `UIMessage`)

```typescript
await ctx.append({
  role: 'assistant',
  parts: [
    { type: 'text', text: 'I can help with that.' },
    { type: 'tool_call', name: 'lookup_manual', payload: { article: 'installing' } }
  ],
  metadata: { reasoning: 'User asked for deployment steps.' }
}, { idempotencyKey: 'msg-017' });

// Optionally pass known token count for accuracy
await ctx.append({
  role: 'assistant',
  parts: [{ type: 'text', text: 'OK!' }]
}, { tokenCount: 12 });
```

Messages are stored exactly as you send them and receive a deterministic `seq` for ordering. Reuse the same `idempotencyKey` when retrying failed requests.

## 3. Build the LLM context and call your model

```typescript
const { usedTokens, messages, needsCompaction } = await ctx.context();

const { text } = await generateText({
  model: openai('gpt-4o-mini'),
  messages
});

await ctx.append({
  role: 'assistant',
  parts: [{ type: 'text', text }]
});
```

`needsCompaction` is a hint; ignore it unless you’ve opted to handle compaction yourself.

## 4. Stream responses

```typescript
// Returns a Response suitable for Next.js/Express.
// Append in onFinish:
return ctx.stream(messages =>
  streamText({
    model: openai('gpt-4o-mini'),
    messages,
    onFinish: async ({ text }) => {
      await ctx.append({ role: 'assistant', parts: [{ type: 'text', text }] });
    },
  })
);
```

Fastpaca fetches the context, calls your function, and streams tokens to your caller. Append the final assistant message in your `onFinish` handler.

## 5. Fetch messages for your UI

```typescript
const latest = await ctx.getTail({ offset: 0, limit: 50 });     // last ~50 messages
const previous = await ctx.getTail({ offset: 50, limit: 50 });  // next page back in time
```

## 6. Optional: manage compaction yourself

```typescript
const { needsCompaction, messages } = await ctx.context();
if (needsCompaction) {
  const { summary, remainingMessages } = await summarise(messages);
  await ctx.compact([
    { role: 'system', parts: [{ type: 'text', text: summary }] },
    ...remainingMessages
  ]);
}
```

This rewrites only what the LLM will see. Users still get the full message log.

## Error handling

- Append conflicts return `409 Conflict` when you pass `ifVersion` (optimistic concurrency).  
- Network retries are safe when you reuse the same `idempotencyKey`.  
- Streaming propagates LLM errors directly; Fastpaca only appends once the stream succeeds.

Notes:
- The server computes message token counts by default; pass `tokenCount` when you have an accurate value.
- Use `ctx.context({ budgetTokens: ... })` to temporarily override the budget.

See the [REST API reference](../api/rest.md) for exact payloads.
