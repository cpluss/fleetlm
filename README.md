# Fastpaca – Context infra for LLM apps

[![Tests](https://github.com/fastpaca/fastpaca/actions/workflows/test.yml/badge.svg)](https://github.com/fastpaca/fastpaca/actions/workflows/test.yml)
[![Docker Build](https://github.com/fastpaca/fastpaca/actions/workflows/docker-build.yml/badge.svg)](https://github.com/fastpaca/fastpaca/actions/workflows/docker-build.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.18.4-purple.svg)](https://elixir-lang.org/)

**Store contexts. Build LLM context. Stream responses.** Fastpaca is a backend-only API that keeps every message durable, keeps your LLM context within budget, and gives you precise compaction hooks—all in one container.

**Context infra for LLM apps.** Fastpaca keeps full history and maintains your LLM context window in one backend service. 
- **Users need to see every message.**
- **LLMs can only see a limited context window.**

Fastpaca bridges that gap with an append-only history, context compaction, and streaming — all inside one backend service. You stay focused on prompts, tools, UI, and business logic. 

- [Docs](https://docs.fastpaca.com) 
- [Quick Start](https://docs.fastpaca.com/usage/quickstart)
- [Architecture](https://docs.fastpaca.com/architecture)

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