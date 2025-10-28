---
title: TypeScript SDK
sidebar_position: 4
---

# TypeScript SDK

These helpers mirror the REST API shown in the Quick Start / Getting Started guides. They accept plain messages with `role` and `parts` (each part has a `type` string). This shape is fully compatible with ai-sdk v5 `UIMessage`, but the SDK does not depend on ai-sdk.

```bash
npm install @fastpaca/fastpaca
```

## 1. Create (or load) a context

```typescript
import { createClient } from '@fastpaca/fastpaca';

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

## 2. Append messages

```typescript
await ctx.append({
  role: 'assistant',
  parts: [
    { type: 'text', text: 'I can help with that.' },
    { type: 'tool_call', name: 'lookup_manual', payload: { article: 'installing' } }
  ],
  metadata: { reasoning: 'User asked for deployment steps.' }
});

// Optionally pass known token count for accuracy
await ctx.append({
  role: 'assistant',
  parts: [{ type: 'text', text: 'OK!' }]
}, { tokenCount: 12 });
```

Messages are stored exactly as you send them and receive a deterministic `seq` for ordering.

## 3. Build the LLM context and call your model

```typescript
const { used_tokens, messages, needs_compaction } = await ctx.context();

const { text } = await generateText({
  model: openai('gpt-4o-mini'),
  messages
});

await ctx.append({
  role: 'assistant',
  parts: [{ type: 'text', text }]
});
```

`needs_compaction` is a hint; ignore it unless you’ve opted to handle compaction yourself.

## 4. Stream responses

```typescript
// Fetch context messages
const { messages } = await ctx.context();

// Stream response with ai-sdk and append in onFinish
return streamText({
  model: openai('gpt-4o-mini'),
  messages,
}).toUIMessageStreamResponse({
  onFinish: async ({ responseMessage }) => {
    await ctx.append(responseMessage);
  },
});
```

The `onFinish` callback receives `{ responseMessage }` in the ai-sdk v5 message shape. Pass it directly to `ctx.append()` to persist to context.

## 5. Fetch messages for your UI

```typescript
const latest = await ctx.getTail({ offset: 0, limit: 50 });     // last ~50 messages
const previous = await ctx.getTail({ offset: 50, limit: 50 });  // next page back in time
```

## 6. Optional: manage compaction yourself

```typescript
const { needs_compaction, messages } = await ctx.context();
if (needs_compaction) {
  const { summary, remainingMessages } = await summarise(messages);
  await ctx.compact([
    { role: 'system', parts: [{ type: 'text', text: summary }] },
    ...remainingMessages
  ]);
}
```

This rewrites only what the LLM will see. Users still get the full message log.

## Error handling

- Append conflicts return `409 Conflict` when you pass `ifVersion` and the context version changed (optimistic concurrency control). On 409, read the current context version and retry with the updated version.
- Network retries: On timeout or 5xx errors, retry the same request (version unchanged). On `409 Conflict`, read context to get updated version, then retry.
- Streaming propagates LLM errors directly; Fastpaca only appends once the stream succeeds.

Notes:
- The server computes message token counts by default; pass `tokenCount` when you have an accurate value (e.g., from your model provider).
- Use `ctx.context({ budgetTokens: ... })` to temporarily override the budget.

Token usage with ai-sdk v5:
- `streamText` and `generateText` expose `usage`/`totalUsage`. If your provider returns completion token counts, pass that as `{ tokenCount }` when appending the assistant’s response for maximum accuracy.

See the [REST API reference](../api/rest.md) for exact payloads.
