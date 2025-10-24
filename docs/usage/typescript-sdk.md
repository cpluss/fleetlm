---
title: TypeScript SDK
sidebar_position: 4
---

# TypeScript SDK

These helpers mirror the REST API shown in the Quick Start / Getting Started guides. They expect ai-sdk style messages (`UIMessage`) and keep the same method names you’ve already seen there.

```bash
npm install fastpaca
```

## 1. Create (or load) a conversation

```typescript
import { createClient } from 'fastpaca';

const fastpaca = createClient({
  baseUrl: process.env.FASTPACA_URL ?? 'http://localhost:4000/v1',
  apiKey: process.env.FASTPACA_API_KEY // optional
});

const ctx = fastpaca.context('123456')
  .budget(1_000_000)  // token budget for this conversation
  .trigger(0.7)       // optional trigger ratio (defaults to 0.7)
  .policy({           // optional policy (defaults to last_n)
    strategy: 'last_n',
    config: { limit: 400 }
  });
```

`context(id)` never creates IDs for you—you decide what to use so you can continue the same conversation later.

## 2. Append messages (ai-sdk `UIMessage`)

```typescript
await ctx.append({
  role: 'assistant',
  parts: [
    { type: 'text', text: 'I can help with that.' },
    { type: 'tool_call', name: 'lookup_manual', payload: { article: 'installing' } }
  ],
  metadata: { reasoning: 'User asked for deployment steps.' }
}, {
  idempotencyKey: 'msg-017'
});
```

Messages are stored exactly as you send them and receive a deterministic `seq` for ordering. Reuse the same `idempotencyKey` when retrying failed requests.

## 3. Build the LLM context and call your model

```typescript
const { usedTokens, messages, needsCompaction } = await ctx.context();

const completion = await generateText({
  model: openai('gpt-4o-mini'),
  messages
});

await ctx.append(completion);
```

`needsCompaction` is a hint; ignore it unless you’ve opted to handle compaction yourself.

## 4. Stream responses

```typescript
return ctx.stream(messages =>
  streamText({ model: openai('gpt-4o-mini'), messages })
).toResponse();
```

Fastpaca fetches the context, calls your function, streams tokens to your caller, and appends the final assistant message. Pass `{ autoAppend: false }` if you want to append manually.

## 5. Fetch messages for your UI

```typescript
const tail = await ctx.get_messages({ tail_offset: 50 });        // last ~50 messages
const previous = await ctx.get_messages({ tail_offset: 100, limit: 50 });
const entireHistory = await ctx.get_messages();
```

## 6. Optional: manage compaction yourself

```typescript
const ctx = fastpaca.context('manual-demo')
  .budget(1_000_000)
  .disable_compaction();

const context = await ctx.context();

if (context.needsCompaction) {
  const head = context.messages.slice(0, -6);
  const summary = await summarize(head);

  await ctx.compact({
    messages: [
      { role: 'system', parts: [{ type: 'text', text: summary }] },
      ...context.messages.slice(-6)
    ]
  });
}
```

This rewrites only what the LLM will see. Users still get the full message log.

## Error handling

- Append conflicts return `409 Conflict` when you pass `ifVersion` (optimistic concurrency).  
- Network retries are safe when you reuse the same `idempotencyKey`.  
- Streaming propagates LLM errors directly; Fastpaca only appends once the stream succeeds.

See the [REST API reference](../api/rest.md) for exact payloads.
