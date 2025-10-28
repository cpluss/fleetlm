---
title: Fastpaca
slug: /
sidebar_position: 0
---

# [Fastpaca](https://fastpaca.com)

**Context infra for LLM apps.** Fastpaca keeps full history and maintains your LLM context window in one backend service. 

- **[Quick Start](./usage/quickstart.md)** – ship a context endpoint in minutes  
- **[Getting Started](./usage/getting-started.md)** – understand how the pieces fit  
- **[API Reference](./api/rest.md)** – REST & websocket surfaces
* **[View source](https://github.com/fastpaca/fastpaca)** - view the source code

---

## Why it matters

- **Users need to see every message.**
- **LLMs can only see a limited context window.**

Fastpaca bridges that gap with an append-only history, context compaction, and streaming — all inside one backend service. You stay focused on prompts, tools, UI, and business logic. 

*(Curious how it’s built? See the [architecture](./architecture.md).)*

---

## How Fastpaca Works

1. **Choose a budget & context policy** – every context sets its token budget and compaction policy up front.
   ```ts
   const ctx = await fastpaca.context('chat_42', {
     budget: 1_000_000,
     trigger: 0.7,
     policy: { strategy: 'last_n', config: { limit: 400 } }
   });
   ```
2. **Append from your backend** – Any message from your LLMs or your users.
   ```ts
   await ctx.append({
     role: 'user',
     parts: [{ type: 'text', text: 'What changed in the latest release?' }]
   });
   ```
3. **Call your LLM** – Fetch the compacted context and hand it to your LLM.
   ```ts
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
4. (optional) **Compact on your terms** – when the policy is set to `manual`.
   ```ts
   const { needs_compaction, messages } = await ctx.context();
   if (needs_compaction) {
     const { summary, remainingMessages } = await summarise(messages);
     await ctx.compact([
       { role: 'system', parts: [{ type: 'text', text: summary }] },
       ...remainingMessages
     ]);
   }
   ```

Need the mental model? Go to [Context Management](./usage/context-management.md). Want to hack now? Hit [Quick Start](./usage/quickstart.md).

---

## Why Teams Pick Fastpaca

- **Stack agnostic** – Bring your own framework. Works natively with ai-sdk v5 (messages are structurally compatible), but ai-sdk is not required. Use LangChain, raw OpenAI/Anthropic calls, whatever you fancy.
- **Horizontally scalable** – Distributed consensus, idempotent appends, automatic failover. Scale nodes horizontally without risk.
- **Token-smart** – Enforce token budgets with built-in compaction policies. Stay within limits automatically.
- **Self-hosted** – Single container by default.

Context context state that doesn’t fall over.

---

## What fastpaca is not

- **Not a vector DB** - bring your own to complement your LLM.
- **Not generic chat infrastructure** - built specifically for LLMs.
- **Not an agent framework** - use it alongside whichever one you prefer.

---

## Where to Go Next

- Ship the basics: [Quick Start](./usage/quickstart.md)  
- Understand policies: [Context Management](./usage/context-management.md)  
- Call the API from code: [TypeScript SDK](./usage/typescript-sdk.md) & [Examples](./usage/examples.md)  
- Learn the internals: [Architecture](./architecture.md) • [API Reference](./api/rest.md)

**Use ai-sdk for inference. Use Fastpaca for context state. Bring your own LLM, framework, and frontend.**
