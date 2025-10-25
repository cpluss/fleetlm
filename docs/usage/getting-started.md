---
title: Getting Started
sidebar_position: 2
---

# Getting Started

Understand how Fastpaca stores contexts and how you work with them day to day.

## Creating a context

Fastpaca works on the concept of *context contexts*. Each context contains two things:

1. **Message log** – what your users see and care about.
2. **LLM context** – what the LLM care about in order to process user requests.

Contexts are created with a unique identifier that you create yourself, as long as it is globally unique it works. That way you can track & reuse contexts in your product.

```typescript
const ctx = fastpaca.context('123456')
  // The token budget for this context, tunable and defaults to 8k to be conservative.
  .budget(1_000_000)  
  // Optionally tune the compaction trigger, ie. at what point will we trigger
  // compaction.
  .trigger(0.7)
  // You can select a compaction policy manually, and eg. only retain 400 
  // messages.
  .policy({ strategy: 'last_n', config: { limit: 400 }})
```

This context acts as your soruce of truth to recognise a context in the future, to be reused across requests. Do note that budget, trigger, and policy are only necessary if you want to tune it - and changing it only changes context behaviour on _new_ contexts created.

*(For more details on how context compaction & management works see [Context Management](./context-management.md))*

## Appending messages

Messages are appended to fastpaca using ai-sdk's protocol to avoid reinventing the wheel, specifically [`UIMessage`](https://ai-sdk.dev/docs/reference/ai-sdk-core/ui-message). It allows us to granularly express messages from LLMs and users including all their parts & components.

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

Fastpaca doesn't care about the shape of the parts, nor metadata, and only require each part to have a `type`. Note that each message is assigned a determinsitic sequence number (`seq`) which is used to order them (total order) within a context.

## Calling your LLM

Request the context whenever you need to call your LLM.

```typescript
const {usedTokens, messages, needsCompaction} = await ctx.context();
const result = await generateText({
  model: openai('gpt-4o-mini'),
  messages: messages
});

// Append the result - do not forget this.
ctx.append(result)
```

The context also stores an *estimated* size of how many tokens it includes, as well as a flag whether compaction is necessary or not. The compaction flag can be safely ignored unless you have explicitly disabled compaction and want to manage it yourself.

## Streaming with your LLM

The best UX streams intermediary results directly to the UI, but not to worry: fastpaca supports this out of the box so you don't need to manually add each part to the context.

```typescript
const stream = ctx.stream((messages) => streamText({
  model: openai('gpt-4o-mini'),
  messages: messages
}));

return stream.toResponse();
```

This will automatically consume the stream results and append them to the context as they arrive, and still allows you to build a responsive product on top.

## Getting messages

Reading messages is fairly straightforward, but can be time consuming. Usually when you build products with context state your users don't see every message at all once, as some contexts can span thousands if not hundreds of thousands of messages. Fetching all of that is slow, regardless of what system you use.

Fastpaca takes this into account and allows you to fetch partial messages based on their sequence numbers, which is used to fetch messages the user can actually see.

```typescript
const ctx = fastpaca.context('12345');

// Fetch the last ~50 messages, most likely stored in
// memory already so should be low latency.
const tail = await ctx.get_messages({ tail_offset: 50 });

// In case your user starts to scroll you may add UI elements to 
// fetch the rest of the context
const one_page_up = await ctx.get_messages({ tail_offset: 100,  limit: 50 });

// Fetches the entire user history, in cases where you have millions of
// messages beware.
const all_messages = await ctx.get_messages();
```

---

## Managing your own compaction

Fastpaca works best when managing compaction for you so you don't need to think about it, but in case you have a product requirement where you need to manage it by yourself it is supported out of the box.

```typescript
const ctx = fastpaca.context('12345')
  // NOTE: this is required, otherwise you'll run compaction
  // twice!
  .disable_compaction();

const { messages, needsCompaction } = await ctx.context();
// We can rewrite history ourselves at any point, but it's best
// to do when we hit the context window thresholds
if (needsCompaction) {
  await ctx.compact({
    // This will completely rewrite the context window that the LLM
    // sees on subsequent requests, but NOT what the user can see.
    messages: [
      { role: 'system', content: summarize(messages) }, 
      ...messages
    ]
  });
}
```

---

Next step: learn how token budgets and strategies work in [Context Management](./context-management.md).
