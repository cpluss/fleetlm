# CLAUDE.md

Guidance for Claude Code when collaborating on FleetLM.

## Quick Start

- `mix setup` — bootstrap deps, DB, and assets
- `mix phx.server` — run the dev server
- `mix test` / `mix test path/to/file.exs` — execute test suites
- `mix precommit` — final gate before handing work back (compile + format + tests)

## Architecture Cheat Sheet

- **Edge nodes** accept HTTP/WebSocket traffic. WebSocket sessions live under `FleetlmWeb.SessionChannel`; inbox summaries stream through `Fleetlm.Runtime.InboxServer`.
- **Owner nodes** host session processes (`Fleetlm.Runtime.SessionServer`). Each session GenServer owns the canonical append-only log, backed by a local disk log that drains to Postgres/S3 on a timer.
- **Sharding** uses a hash ring (`Fleetlm.Runtime.HashRing`) so every session resolves to a single owner. Ring changes drain in-flight sessions before handoff.
- **Agents** are external systems reached via pooled webhooks. `Fleetlm.Agent.Debouncer` batches rapid messages using timers; `Fleetlm.Agent.WebhookWorker` handles delivery. Telemetry tracks throughput, debounce delay, and end-to-end latency.
- **Inbox model**: one inbox per participant, many sessions per participant. Runtime keeps inbox snapshots in Cachex and relies on sequence numbers for replay.

## Working Standards

- Pattern-match required input (controller params, channel payloads, webhook data); return descriptive errors when the shape is wrong. Do not mask missing keys with `Map.get(..., default)`.
- Make telemetry strict. Add clauses like `defp message_tags(%{role: role})` and treat everything else as the fallback path that highlights anomalies.
- When serialising structs/maps, destructure once and build the response. Avoid peppering `Map.get` across atom/string variants—normalise at the boundary.
- Use `Req` for outbound HTTP. Provide timeouts and error handling that surfaces failures to logs + telemetry.
- Lint, format, and test locally. Every PR should pass `mix precommit`.

## Domain Assumptions & Conventions

- Conversations are always human ↔ agent. UI and APIs assume exactly one agent per session.
- Messages are at-least-once; clients resend `last_seq` on reconnect and expect replay. Keep sequence handling intact when modifying routers or runtime.
- Session and inbox processes are transient: they boot lazily, drain cleanly, and can be rebuilt from storage. Code must tolerate restarts without data loss.
- LiveView templates begin with `<Layouts.app ...>`; forms use `<.form>`/`<.input>` combos, icons use `<.icon>`.
- Tailwind v4 is the styling backbone. Maintain the stock import stanza and craft micro-interactions via utility classes.

## Tooling Shortcuts

- `mix ecto.migrate` / `mix ecto.rollback` for schema changes
- `mix assets.build` for rebuilding Tailwind + JS bundles
- `mix phx.gen.html` / `mix phx.gen.live` are unused—prefer handcrafted components consistent with the design language

## Checklist Before You Finish

1. All new/modified modules follow the fail-loud, pattern-matching style.
2. Telemetry tags remain explicit; no new "unknown" defaults unless product requirements demand it.
3. Tests cover new code paths, especially LiveView/Channel interactions and agent webhooks.
4. Run `mix precommit` and address every warning, formatter diff, and test failure.
5. Document runtime changes (process lifecycles, sharding, agent flows) in `docs/` if behaviour shifts meaningfully.
