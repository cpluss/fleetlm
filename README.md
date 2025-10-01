# FleetLM - Open Source Engine for Stateless Agents

[![Tests](https://github.com/cpluss/fleetlm/actions/workflows/test.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/test.yml)
[![Docker Build](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml/badge.svg)](https://github.com/cpluss/fleetlm/actions/workflows/docker-build.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Elixir](https://img.shields.io/badge/Elixir-1.15.7-purple.svg)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8.1-red.svg)](https://phoenixframework.org/)

Write stateless agents. We handle the WebSockets.

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

## Roadmap

### v0.1 - Core runtime (now)

- [x] Postgres-backed DM + broadcast persistence
- [x] Phoenix PubSub fan-out with optional Redis transport
- [x] Conversation and inbox websocket channels
- [x] REST API for history + send operations
- [x] Cachex tails and inbox snapshots
- [x] Operator/agent CLI client
- [ ] Reference Dockerfile + docker compose example

### v0.2 - Developer experience

- [ ] Official TypeScript SDK (`@fleetlm/js`)
- [ ] Python SDK (`fleetlm`)
- [ ] Example app showing webhook-bridged agents
- [ ] Container image + Helm chart for Kubernetes installs

### v0.3 - Agent bridge (webhooks)

- [ ] Managed webhook delivery (message.created, inbox.updated, broadcast.created)
- [ ] Subscription management UI + signing secrets
- [ ] Stateless agent helpers (retry, exponential backoff, idempotency keys)
- [ ] Event replay for at-least-once delivery guarantees

### v0.4 - Operational scale

- [ ] Sharded Redis pub/sub and partition-aware supervisors
- [ ] Prometheus/Grafana dashboards bundled with PromEx presets
- [ ] Configurable rate limits and abuse controls
- [ ] Admin console (connections, queues, throughput)

### v0.5 - Rich conversations

- [ ] File attachments via S3-compatible storage
- [ ] Search + semantic metadata indexing
- [ ] Retention policies, GDPR delete workflows
- [ ] Analytics APIs and health monitoring

## Contributing

We love contributions. Before opening a pull request:

1. Run `mix precommit` (compile with warnings-as-errors, format, and test).
2. Document behaviour or add tests where it adds clarity.
3. Share the validation steps you ran.

## License

FleetLM is released under the [Apache 2.0 License](LICENSE).
