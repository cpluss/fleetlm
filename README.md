# fastpaca

[![Tests](https://github.com/fastpaca/fastpaca/actions/workflows/test.yml/badge.svg)](https://github.com/fastpaca/fastpaca/actions/workflows/test.yml)
[![Docker Build](https://github.com/fastpaca/fastpaca/actions/workflows/docker-build.yml/badge.svg)](https://github.com/fastpaca/fastpaca/actions/workflows/docker-build.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.18.4-purple.svg)](https://elixir-lang.org/)

Context budgeting and compaction for LLM apps. Keep long conversations fast and affordable.

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
- [API Reference](./api/rest.md)

## Long conversations get expensive and slow

- More messages = more tokens = higher cost
- Larger context = slower responses
- Eventually you hit the model's limit

## What fastpaca does

Enforces per-conversation token budgets with deterministic compaction.

- Keep full history for users
- Compact context for the model
- Choose your policy (`last_n`, `skip_parts`, `manual`)

<details>
<summary><b>Example: last_n policy (keep recent messages)</b></summary>

**Before** (10 messages):
```ts
[
  { role: 'user', text: 'What's the weather?' },
  { role: 'assistant', text: '...' },
  { role: 'user', text: 'Tell me about Paris' },
  { role: 'assistant', text: '...' },
  // ... 6 more exchanges
  { role: 'user', text: 'Book a flight to Paris' }
]
```

**After** `last_n` policy with limited budget (3 messages):
```ts
[
  { role: 'user', text: 'Tell me about Paris' },
  { role: 'assistant', text: '...' },
  { role: 'user', text: 'Book a flight to Paris' }
]
```

Full history stays in storage. Only compact context goes to the model.
</details>

<details>
<summary><b>Example: skip_parts policy (drop heavy content)</b></summary>

**Before** (assistant message with reasoning + tool results):
```ts
{
  role: 'assistant',
  parts: [
    { type: 'reasoning', text: '<3000 tokens of chain-of-thought>' },
    { type: 'tool_use', name: 'search', input: {...} },
    { type: 'tool_result', content: '<5000 tokens of search results>' },
    { type: 'text', text: 'Based on the search, here's the answer...' }
  ]
}
```

**After** `skip_parts` policy (keeps message structure, drops bulk):
```ts
{
  role: 'assistant',
  parts: [
    { type: 'text', text: 'Based on the search, here's the answer...' }
  ]
}
```

Drops reasoning traces, tool results, images — keeps the final response. Massive token savings while preserving conversation flow.
</details>

## Quick Start

> [!TIP]
> [See example](./examples/nextjs-chat/README.md) for a more comprehensive look at how it looks in a real chat app!

Start container, note that postgres is optional. Data will persist in memory with a TAIL for message history.

```
```bash
docker run -d \
  -p 4000:4000 \
  -v fastpaca_data:/data \
  ghcr.io/fastpaca/fastpaca:latest
```

Use our typescript SDK

```ts
import { createClient } from '@fastpaca/fastpaca';

const fastpaca = createClient({ baseUrl: 'http://localhost:4000/v1' });
const ctx = await fastpaca.context('demo', { budget: 1_000_000 });
await ctx.append({ role: 'user', parts: [{ type: 'text', text: 'Hi' }] });

// For your LLM
const { messages } = await ctx.context();
```

## When to use fastpaca

**Good fit:**
- Multi-turn conversations that grow unbounded
- Agent apps with heavy tool use and reasoning traces
- Apps that need full history retention + compact model context
- Scenarios where you want deterministic, policy-based compaction

**Not a fit (yet):**
- Single-turn Q&A (no conversation state to manage)
- Apps that need semantic compaction (we're deterministic, not embedding-based)

## Background

We kept rebuilding the same Redis + Postgres + pub/sub stack to manage conversation state and compaction. It was messy, hard to scale, and expensive to tune.
Fastpaca turns that pattern into a single service you can drop in.

---

## Development

```bash
# Clone and set up
git clone https://github.com/fastpaca/fastpaca
cd fastpaca
mix setup            # install deps, create DB, run migrations

# Start server on http://localhost:4000
mix phx.server

# Run tests / precommit checks
mix test
mix precommit        # format, compile (warnings-as-errors), test
```

### Storage tiers

- **Hot (Raft):** LLM context window + bounded message tail. Raft snapshots include these plus watermarks (`last_seq`, `archived_seq`).
- **Cold (optional):** Archiver persists full history to Postgres and acknowledges a high-water mark so Raft can trim older tail segments.

---

## Contributing

We welcome pull requests. Before opening one:

1. Run `mix precommit` (format, compile, test)
2. Add tests for new behaviour
3. Update docs if you change runtime behaviour or message flow

If you use a coding agent, make sure it follows `AGENTS.md`/`CLAUDE.md` and review all output carefully.
