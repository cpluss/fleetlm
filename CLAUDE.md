# CLAUDE.md

Guidance for Claude Code when collaborating on FleetLM.

## Quick Start

- `mix setup` — bootstrap deps, DB, and assets
- `mix phx.server` — run the dev server
- `mix test` / `mix test path/to/file.exs` — execute test suites
- `mix precommit` — final gate before handing work back (compile + format + tests)

## Architecture Cheat Sheet

- **Edge nodes** accept HTTP/WebSocket traffic via `FleetlmWeb.SessionChannel`. Inbox summaries stream through `Fleetlm.Runtime.InboxServer`.
- **Owner nodes** host `Fleetlm.Runtime.SessionServer` processes. Each SessionServer writes to a WAL-based commit log (`Fleetlm.Storage.SlotLogServer`) that flushes to Postgres every 300ms (configurable).
- **Sharding** uses `Fleetlm.Runtime.HashRing` (consistent hashing) + `SessionTracker` (Phoenix.Tracker CRDT) for distributed session routing. Ring changes mark sessions as `:draining`, block new appends, flush to DB, then handoff to new owner.
- **Agents** are external HTTP endpoints. `Fleetlm.Agent.Engine` polls an ETS queue (`:agent_dispatch_queue`) every 50ms, spawns supervised tasks for webhooks, and streams JSONL responses back into sessions.
- **Inbox model**: one inbox per user, many sessions per user. Runtime keeps inbox snapshots in Cachex, relies on sequence numbers for replay.
- **Supervision**: `Runtime.Supervisor` uses `:one_for_one` strategy. SessionServer crashes restart individually (`:transient`), SlotLogServer crashes are isolated per slot (`:permanent`). No cascading failures.

## Working Standards

- Pattern-match required input (controller params, channel payloads, webhook data); return descriptive errors when the shape is wrong. Do not mask missing keys with `Map.get(..., default)`.
- Make telemetry strict. Add clauses like `defp message_tags(%{role: role})` and treat everything else as the fallback path that highlights anomalies.
- When serialising structs/maps, destructure once and build the response. Avoid peppering `Map.get` across atom/string variants—normalise at the boundary.
- Use the shared agent engine for outbound HTTP. It uses Finch with HTTP/2 connection pooling—avoid reintroducing ad-hoc HTTP clients on the hot path.
- Lint, format, and test locally. Every PR should pass `mix precommit`.

## Domain Assumptions & Conventions

- Conversations are always human ↔ agent. UI and APIs assume exactly one agent per session.
- Messages are at-least-once; clients resend `last_seq` on reconnect and expect replay. Keep sequence handling intact when modifying routers or runtime.
- Session and inbox processes are transient: they boot lazily, drain cleanly, and rebuild from WAL cursors + Postgres on restart. Code must tolerate restarts without data loss.
- **WAL storage**: Messages append to disk (`Fleetlm.Storage.CommitLog`) in 128MB segments. Cursors track `{segment, offset}` flush positions. Invalid cursors default to `{0, 0}` with a warning—no crashes.
- **Background flush**: SlotLogServer streams WAL segments to Postgres in 4MB chunks via supervised tasks. Batches up to 5000 messages/insert (Postgres param limit).
- LiveView templates begin with `<Layouts.app ...>`; forms use `<.form>`/`<.input>` combos, icons use `<.icon>`.
- Tailwind v4 is the styling backbone. Maintain the stock import stanza and craft micro-interactions via utility classes.

## Tooling Shortcuts

- `mix ecto.migrate` / `mix ecto.rollback` for schema changes
- `mix assets.build` for rebuilding Tailwind + JS bundles
- `mix phx.gen.html` / `mix phx.gen.live` are unused—prefer handcrafted components consistent with the design language

## Checklist Before You Finish

1. All new/modified modules follow the fail-loud, pattern-matching style.
2. Telemetry tags remain explicit; no new "unknown" defaults unless product requirements demand it.
3. Tests cover new code paths, especially LiveView/Channel interactions, agent webhooks, and WAL/cursor recovery.
4. Run `mix precommit` and address every warning, formatter diff, and test failure.
5. Document runtime changes (process lifecycles, sharding, agent flows, storage) in `docs/` if behaviour shifts meaningfully.

## Hot Path Design

Keep the critical path flat: append to WAL, fsync in batches (512KB/25ms), publish immediately. Background tasks flush to Postgres without blocking the write path.
