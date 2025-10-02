# FleetLM - Open Source Engine for Stateless Agents

[![Tests](https://github.com/cpluss/fleetlm/actions/workflows/test.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/test.yml)
[![Docker Build](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Elixir](https://img.shields.io/badge/Elixir-1.15.7-purple.svg)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8.1-red.svg)](https://phoenixframework.org/)

Write stateless agents. We handle the rest.

FleetLM is the conversation layer between your users and your agents. Your agent is a HTTP endpoint - FleetLM provides WebSockets, message persistence, ordering, and replay so you never build chat infrastructure yourself.

## How it works

1. **You register your agents** and include a webhook URL (self-host today, managed registration lands in v0.3).
2. **Users create sessions and send messages** through FleetLM webSocket channels.
3. **FleetLM delivers webhooks** (coming soon) or PubSub events with the full conversation context so your stateless service can decide the next action.

## Quick start (5 minutes)

```bash
$ git clone https://github.com/cpluss/fleetlm
$ cd fleetlm && docker compose up --build
$ curl http://localhost:4000/health || curl http://localhost:8080/health
```

## Contributing

We love contributions. Before opening a pull request:

1. Run `mix precommit` (compile with warnings-as-errors, format, and test).
2. Document behaviour or add tests where it adds clarity.
3. Share the validation steps you ran.

## License

FleetLM is released under the [Apache 2.0 License](LICENSE).
