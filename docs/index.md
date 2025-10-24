---
title: Fastpaca
slug: /
sidebar_position: 0
---

# Fastpaca

**Context infra for LLM apps.** Fastpaca keeps full history and maintains your LLM context window in one backend service. 

- **[Quick Start](./usage/quickstart.md)** – ship a conversation endpoint in minutes  
- **[Getting Started](./usage/getting-started.md)** – understand how the pieces fit  
- **[API Reference](./api/rest.md)** – REST & websocket surfaces

---

## Why it matters

- **Users need to see every message.**
- **LLMs can only see a limited context window.**

Fastpaca bridges that gap with an append-only history, context compaction, and streaming — all inside one backend service. You stay focused on prompts, tools, UI, and business logic. 

*(Curious how it’s built? See the [architecture](./architecture.md).)*

---

## How Fastpaca Works

1. **Choose a budget & strategy** – every context sets its token budget and compaction policy up front. Use built-ins (`last_n`, `strip_tool_results`, `budget`, time-aware) or register your own module.  
   ```ts
   const ctx = await fastpaca.context('chat_42')
     .budget(1_000_000)
     .trigger(0.7 /* 70% */)
     .policy({ strategy: 'last_n', config: { limit: 400 } });
   ```
2. **Append from your backend** – Fastpaca stores every event in an append-only log (Raft, idempotent writes).  
   ```ts
   await ctx.append({
     role: 'user',
     content: 'What changed in the latest release?'
   });
   ```
3. **Fetch the window & call your LLM** – ask for the token-budgeted transcript and hand it to ai-sdk, LangChain, or raw SDKs.  
   ```ts
   const stream = ctx.stream((messages) => streamText({
     model: openai('gpt-4o-mini'),
     messages: messages
   }));

   return stream.toResponse();
   ```
4. (optional) **Compact on your terms** – `needCompaction` indicates we hit the budget, and you can rewrite history whenever you want.
   ```ts
   if (window.needsCompaction) {
     await ctx.compact({
       messages: [
         { role: 'system', content: summarize(messages) }, 
         ...messages
       ]
     });
   }
   ```

Fastpaca never sits between your frontend and model. It’s backend-only: append, window, compact, replay, stream.

Need the mental model? Go to [Context Management](./usage/context-management.md). Want to hack now? Hit [Quick Start](./usage/quickstart.md).

---

## Why Teams Pick Fastpaca

- **Stack agnostic** – works with ai-sdk, LangChain, raw OpenAI/Anthropic calls.  
- **Durable by default** – distributed system consensus, idempotent appends, zero silent drops.  
- **Token-smart** – enforce token budgets with plug and play compaction strategies.
- **Self-hosted** – single container, add nodes to cluster with automatic failover, optional Postgres write-behind.  

No agents. No RAG. No model proxy. Only context conversation state that doesn’t fall over.

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

**Use ai-sdk for inference. Use Fastpaca for conversation state. Bring your own model, framework, and frontend.**
