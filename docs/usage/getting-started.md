---
title: Getting Started
sidebar_position: 2
---

# Getting Started

Understand how Fastpaca stores contexts and how you work with them day to day.

## Creating a context

Fastpaca works with contexts. Each context contains two things:

1. **Message log**: what your users see and care about.
2. **LLM context**: what the LLM cares about in order to process user requests.

Contexts are created with a unique identifier that you choose. As long as it is globally unique, it works. That way you can track and reuse contexts in your product.

```typescript
import { createClient } from '@fastpaca/fastpaca';

const fastpaca = createClient({ baseUrl: process.env.FASTPACA_URL || 'http://localhost:4000/v1' });
const ctx = await fastpaca.context('123456', {
  // The token budget for this context, tunable and defaults to 8k to be conservative.
  budget: 1_000_000,
  // Optionally tune the compaction trigger, i.e. at what point will we trigger compaction.
  trigger: 0.7,
  // You can select a compaction policy manually, and e.g. only retain 400 messages.
  policy: { strategy: 'last_n', config: { limit: 400 } }
});
```

This context acts as your source of truth to recognise in the future and reuse across requests. Note that budget, trigger, and policy are optional; changing them only affects the behaviour of contexts you create after the change.

*(For more details on how context compaction & management works see [Context Management](./context-management.md))*

## Appending messages

Messages are plain objects with a `role` and an array of `parts`. Each part must include a `type` string. This structure is fully compatible with ai-sdk v5 `UIMessage`, but Fastpaca does not require ai-sdk and works with any message that follows this shape.

```typescript
await ctx.append({
  role: 'assistant',
  parts: [
    { type: 'text', text: 'I can help with that.' },
    { type: 'tool_call', name: 'lookup_manual', payload: { article: 'installing' } }
  ],
  metadata: { reasoning: 'User asked for deployment steps.' }
});
```

Fastpaca doesn't care about the specific shape of parts or metadata; it only requires that each part has a `type`. Each message is assigned a deterministic sequence number (`seq`) used to order them within a context.

## Calling your LLM

Request the context whenever you need to call your LLM.

```typescript
const { used_tokens, messages, needs_compaction } = await ctx.context();
const result = await generateText({
  model: openai('gpt-4o-mini'),
  messages
});

// Append the result - do not forget this.
await ctx.append({ role: 'assistant', parts: [{ type: 'text', text: result.text }] });
```

The context also stores an estimated `used_tokens` count and a `needs_compaction` flag. You can safely ignore `needs_compaction` unless you've opted to manage compaction yourself.

## Streaming with your LLM

Stream intermediate results directly to the UI while persisting them to context.

```typescript
const { messages } = await ctx.context();
return streamText({
  model: openai('gpt-4o-mini'),
  messages,
}).toUIMessageStreamResponse({
  onFinish: async ({ responseMessage }) => {
    await ctx.append(responseMessage);
  },
});
```

The `onFinish` callback receives `{ responseMessage }` with the properly formatted UIMessage when streaming completes. Pass it directly to `ctx.append()` to persist to context. Users see tokens stream in real-time while the full message is persisted.

## Getting messages

Reading messages is straightforward but can be time-consuming. Usually, users don't see every message all at once, as some contexts can span thousands if not hundreds of thousands of messages. Fetching all of that is slow, regardless of what system you use.

Fastpaca takes this into account and lets you fetch partial messages based on sequence numbers, which is what you actually render.

```typescript
const ctx = await fastpaca.context('12345');

// Fetch the last ~50 messages (from the tail)
const latest = await ctx.getTail({ offset: 0, limit: 50 });

// If the user scrolls, fetch the next page
const onePageUp = await ctx.getTail({ offset: 50, limit: 50 });
```

---

## Managing your own compaction

Fastpaca works best when managing compaction for you so you don't need to think about it, but in case you have a product requirement where you need to manage it by yourself it is supported out of the box.

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

---

Next step: learn how token budgets and strategies work in [Context Management](./context-management.md).
