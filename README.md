# FleetLM - Context infra for LLM apps

[![Tests](https://github.com/cpluss/fleetlm/actions/workflows/test.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/test.yml)
[![Docker Build](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Elixir](https://img.shields.io/badge/Elixir-1.18.4-purple.svg)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8.1-red.svg)](https://phoenixframework.org/)

Context management is killing your costs. RAG + pub/sub + compaction + persistence = complexity that balloons fast.

FleetLM handles the full lifecycle: persist, replay, compact, deliver.

[Website](https://fleetlm.com/) · [Documentation](https://docs.fleetlm.com/) · [Benchmarks](https://fleetlm.com/#benchmarks)

---

## The Context Complexity Trap

1. Simple LLM calls → works great
2. Add persistence → need database
3. Multi-device sync → need pub/sub
4. Context limits hit → need compaction
5. Debug sessions → need event log
6. **Five systems. Distributed nightmare.**

**FleetLM does all of this out of the box.**

Write stateless REST. Deploy with docker compose. We handle state, ordering, replay and soon compaction.

---

## Quick Start

```bash
# Checkout the repository
git clone https://github.com/cpluss/fleetlm
cd fleetlm

# Start postgres + fleetlm
docker compose up
```

Server runs at `http://localhost:4000` with WebSocket endpoint at `ws://localhost:4000/socket`.

**Next steps:**
- [Register an agent](https://docs.fleetlm.com/quickstart#register-an-agent)
- [Send your first message](https://docs.fleetlm.com/quickstart#send-a-message)

## Development

- [Read the architecture](https://docs.fleetlm.com/architecture)
- Local setup without Docker:

```bash
mix setup          # Install deps, create DB, run migrations
mix phx.server     # Start server on :4000
mix test           # Run test suite
mix precommit      # Format, compile (warnings-as-errors), test
```

## Contributing

Before opening a PR:

1. Run `mix precommit` (compile, format, test)
2. Add tests for new behavior
3. Update docs if you change runtime or message flow

If you use a coding agent (claude, codex, etc) make sure they follow `CLAUDE.md` or `AGENTS.md`, and carefully review all output.

## License

Apache 2.0 - see [LICENSE](LICENSE)

---

**FleetLM makes LLM infra as boring as it should be.**

Run it once, and stop thinking about gnarly chat infra.

© 2025 FleetLM. All rights reserved.
