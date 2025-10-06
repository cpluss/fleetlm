# FleetLM

[![Tests](https://github.com/cpluss/fleetlm/actions/workflows/test.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/test.yml)
[![Docker Build](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Elixir](https://img.shields.io/badge/Elixir-1.18.4-purple.svg)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8.1-red.svg)](https://phoenixframework.org/)

> [!NOTE]
> **Work in Progress**: FleetLM is under active development. APIs and behavior may change. Please [report any issues](https://github.com/cpluss/fleetlm/issues) you encounter.

**Write stateless agents. We handle the rest.**

FleetLM is a conversation engine for stateless AI agents. Point at your HTTP endpoint, it provides WebSockets, message persistence, ordering, and replay. Agentic chat infrastructure that scales.

Built on Elixir/OTP for fault isolation and horizontal scaling.

## How It Works

1. **Register your agent** with a webhook URL
2. **Users connect via WebSocket** and send messages
3. **FleetLM delivers webhooks** with conversation context
4. **Your agent responds** (JSONL streaming supported)
5. **Messages persist** and replay on reconnect

## Quick Start

```bash
# Checkout the repository
$> git clone https://github.com/cpluss/fleetlm
$> cd fleetlm

# Start postgres + fleetlm
$> docker compose up --build
```

Server runs at `http://localhost:4000` with WebSocket endpoint at `ws://localhost:4000/socket`.

**Next steps:**
- [Register an agent](docs/quickstart.md#2-register-an-agent)
- [Send your first message](docs/quickstart.md#4-send-a-message)

## Development

- [Read the architecture](docs/architecture.md)
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

## License

Apache 2.0 - see [LICENSE](LICENSE)
