---
title: Fastpaca
slug: /
sidebar_position: 0
---

# fastpaca

Context budgeting and compaction for LLM apps. Keeep long conversations fast and affordable.

- Set token budgets. Conversations stay within bounds.
- You control the accuracy/cost tradeoff.

```
                      ╔═ fastpaca ════════════════════════╗
╔══════════╗          ║                                   ║░    ╔═optional═╗          
║          ║░         ║  ┏━━━━━━━━━━━┓     ┏━━━━━━━━━━━┓  ║░    ║          ║░         
║  client  ║░───API──▶║  ┃  Message  ┃────▶┃  Context  ┃  ║░ ──▶║ postgres ║░
║          ║░         ║  ┃  History  ┃     ┃  Policy   ┃  ║░    ║          ║░         
╚══════════╝░         ║  ┗━━━━━━━━━━━┛     ┗━━━━━━━━━━━┛  ║░    ╚══════════╝░         
 ░░░░░░░░░░░░         ║                                   ║░     ░░░░░░░░░░░░         
                      ╚═══════════════════════════════════╝░                      
                       ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

> _Enforces a per-conversation token budget before requests hit your LLM._

- [Quick start](./usage/quickstart.md)
- [Getting started](./usage/getting-started.md)
- [How it Works](./architecture.md)
- [Policies](./usage/context-management.md)
- [Self-hosting](./deployment.md)
- [Storage & Audit](./storage.md)
- [API Reference](./api/rest.md)

# Long conversations get expensive and slow

- More messages = more tokens = higher cost
- Larger context = slower responses
- Eventually you hit the model's limit

## What fastpaca does

Enforces per-conversation token budgets with deterministic compaction.

- Keep full history for users
- Compact context for the model
- Choose your policy (`last_n`, `skip_parts`, `manual`)

## Quick Start

```ts
const fastpaca = createClient({ baseUrl: 'http://localhost:4000/v1' });
const ctx = await fastpaca.context('demo', { budget: 1_000_000 });
await ctx.append({ role: 'user', parts: [{ type: 'text', text: 'Hi' }] });
const { messages } = await ctx.context();
```

## Background

We kept rebuilding the same Redis + Postgres + pub/sub stack to manage conversation state and compaction. It was messy, hard to scale, and expensive to tune.  
Fastpaca turns that pattern into a single service you can drop in.
