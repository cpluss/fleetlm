# fastpaca

[![Tests](https://github.com/fastpaca/fastpaca/actions/workflows/test.yml/badge.svg)](https://github.com/fastpaca/fastpaca/actions/workflows/test.yml)
[![Docker Build](https://github.com/fastpaca/fastpaca/actions/workflows/docker-build.yml/badge.svg)](https://github.com/fastpaca/fastpaca/actions/workflows/docker-build.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.18.4-purple.svg)](https://elixir-lang.org/)

Context budgeting and compaction for LLM apps. Keeep long conversations fast and affordable.

- Set token budgets. Conversations stay within bounds.
- You control the accuracy/cost tradeoff.

```
                      ╔═ fastpaca ════════════════════════╗
╔══════════╗          ║                                   ║░
║          ║░         ║  ┏━━━━━━━━━━━┓     ┏━━━━━━━━━━━┓  ║░
║  client  ║░───API──▶║  ┃  Message  ┃────▶┃  Context  ┃  ║░
║          ║░         ║  ┃  History  ┃     ┃  Policy   ┃  ║░
╚══════════╝░         ║  ┗━━━━━━━━━━━┛     ┗━━━━━━━━━━━┛  ║░
 ░░░░░░░░░░░░         ║                                   ║░
                      ╚═══════════════════════════════════╝░
                       ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

> _Enforces a per-conversation token budget before requests hit your LLM._

- [Quick start](https://docs.fastpaca.com/usage/quickstart)
- [Getting started](https://docs.fastpaca.com/usage/getting-started)
- [How it Works](https://docs.fastpaca.com/architecture)
- [Policies](https://docs.fastpaca.com/usage/context-management)
- [Self-hosting](https://docs.fastpaca.com/deployment)
- [API Reference](https://docs.fastpaca.com/api/rest)

# Why it exists 

Long conversations get expensive and slow

- Every extra message adds tokens.
- Tokens add latency and cost.
- Without control conversations drift until they slow down or hit limits.

## What fastpaca does

Enforces per-conversation token budgets with deterministic compaction.

- Keep full history visible to users
- Compact context for the LLM to fit a fixed budget you configure
- Choose your policy (`last_n`, `skip_parts`, `manual`)

## Quick Start


This creates a context and enforces a 1M-token budget.

```ts
const fastpaca = createClient({ baseUrl: 'http://localhost:4000/v1' });
const ctx = await fastpaca.context('demo', { budget: 1_000_000 });
await ctx.append({ role: 'user', parts: [{ type: 'text', text: 'Hi' }] });
const { messages } = await ctx.context();
```

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

---

## Contributing

We welcome pull requests. Before opening one:

1. Run `mix precommit` (format, compile, test)
2. Add tests for new behaviour
3. Update docs if you change runtime behaviour or message flow

If you use a coding agent, make sure it follows `AGENTS.md`/`CLAUDE.md` and review all output carefully.
