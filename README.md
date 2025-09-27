# FleetLM - Open Source Engine for Stateless Agents

Write stateless agents. We handle the WebSockets.

FleetLM is the open-source Phoenix/Elixir runtime that powers the FleetLM enterprise platform. It gives you the production-ready backend for multi-user, multi-agent conversations while letting your agents stay simple HTTP services. Self-host it for free, or grow into the managed cloud when you want turn-key scaling, fully managed webhooks, and enterprise uptime.

## Why FleetLM

- Backend for your conversational offering: plug FleetLM into your product to unlock reliable messaging, persistence, and fan-out without reinventing chat infrastructure.
- Agents as HTTP endpoints: register an agent, send it a DM, and let FleetLM deliver the full conversation context to the webhook it exposes.
- Stateless by design: sessions, reconnects, and conversation history live in FleetLM so your agents can scale horizontally without sticky WebSocket connections.
- Production infrastructure included: ordered delivery, Redis-backed PubSub fan-out, cache-coherent read models, Prometheus metrics, and OpenTelemetry spans out of the box.
- Open source first: Apache 2.0 license, no usage caps. When you need SLAs, analytics, and hosted webhooks, FleetLM Cloud sits on the same core runtime.

## How it works

1. **Agent registers** as a participant and advertises a webhook URL (self-host today, managed registration lands in v0.3).
2. **Users or other agents send DMs** through FleetLM REST APIs or WebSocket channels.
3. **FleetLM delivers webhooks** (coming soon) or PubSub events with the full conversation context so your stateless service can decide the next action.

Until the managed webhook service ships, you can subscribe directly to Phoenix PubSub topics (`conversation:*`, `inbox:*`) or bridge them into your own webhook dispatcher.

## Quick start (5 minutes)

```bash
$ git clone https://github.com/fleetlm/fleetlm
$ cd fleetlm && docker compose up --build
$ curl http://localhost:4000/health || curl http://localhost:8080/health
```

Prefer local development?

```bash
mix setup
mix phx.server
```

The REST API listens on `http://localhost:4000`, and the WebSocket endpoint on `ws://localhost:4000/socket`.

## Build stateless agents today

Agents only need to speak HTTP. A minimal pattern looks like this:

```elixir
# lib/my_agent_webhook.ex
plug :match
plug :dispatch

post "/webhooks/conversation" do
  %{"conversation" => messages, "dm_key" => dm_key} = Plug.Conn.read_body!(conn) |> Jason.decode!()

  response = decide_next_step(messages)

  Req.post!("http://localhost:4000/api/conversations/#{dm_key}/messages", json: %{
    sender_id: "shipping-bot",
    text: response.text,
    metadata: response.metadata
  })

  send_resp(conn, 204, "")
end
```

Back the webhook with a FleetLM PubSub subscription while first-class webhook delivery is finalized:

```elixir
:ok = Phoenix.PubSub.subscribe(Fleetlm.PubSub, "conversation:alice:shipping-bot")

receive do
  {:dm_message, payload} -> MyAgentWebhook.enqueue(payload)
end
```

When v0.3 lands, FleetLM will call your webhook directly with HMAC-signed payloads, retries, and delivery metrics.

## Core capabilities

- **Persistent sessions** stored in Postgres via the `Fleetlm.Conversation` context, keeping humans and agents in sync.
- **Realtime fan-out** through Phoenix Channels and REST fallbacks when WebSockets are blocked.
- **Inbox intelligence** with per-participant supervisors that track unread counts, last message previews, and cache snapshots for fast reconnects.
- **Scalable runtime** built on DynamicSupervisors, Redis-ready PubSub, and Cachex-backed hot caches.
- **Observability** via PromEx dashboards and OpenTelemetry hooks for end-to-end tracing.
- **Operator tooling** including a CLI (`scripts/test_client.exs`) that doubles as a human interface or LLM tool.

## Perfect for

- **Customer support handoffs**: agents deflect common issues, humans join with full context, no missing history.
- **Multi-agent orchestration**: specialized bots collaborate, @mention each other, and let FleetLM enforce ordering.
- **Collaborative workspaces**: multiple users and AI co-editing in real time while FleetLM owns the WebSocket complexity.
- **Educational tutors**: lessons that span days or weeks with persistent conversation state and replayable history.
- **Workflow automation**: webhook-driven agents that pause, call external APIs, and rejoin the thread when results arrive.
- **Low-latency trading desks**: human traders and bots share a channel with ordered delivery over resilient WebSockets.

## Platform architecture (snapshot)

| Concern | FleetLM module | Notes |
| --- | --- | --- |
| API surface | `Fleetlm.Runtime.Gateway`, REST controllers, WebSocket channels | Stateless boundary for append/replay/mark-read |
| Session orchestration | `Fleetlm.Runtime.SessionServer` | One GenServer per session for ordered fan-out and cache hydration |
| Inbox state | `Fleetlm.Runtime.InboxServer` | Aggregates sessions per participant, debounced updates over PubSub |
| Caching | `Cachex` via `Fleetlm.Runtime.Cache` | Session tails, inbox snapshots, read cursors |
| Persistence | `Fleetlm.Conversation` | Ecto context + schemas for sessions/messages |
| Observability | `Fleetlm.Observability` | PromEx metrics, OpenTelemetry spans |
| Tooling | `scripts/test_client.exs` | JSONL CLI for humans or LLM agents |

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
