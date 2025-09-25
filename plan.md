# FleetLM Agent Sessions Rewrite Plan

## Overview
Complete redesign of the chat runtime to support multi-session, agent-integrated conversations while keeping write paths append-only. The new architecture introduces explicit chat sessions (two participants), first-class participants, webhook-capable agents, and delivery observability. Each phase keeps the system in a runnable state.

## Phase 0 – Domain Blueprint & Guard Rails
- Finalize ERD for `participants`, `chat_sessions`, `chat_messages`, `agent_endpoints`, `agent_delivery_logs`
- `chat_sessions` holds both participant identifiers (`initiator_id`, `peer_id`) plus optional `agent_id` shortcut
- Document message payload contract (`kind`, `content`, `metadata`, `seq`)
- Capture migration approach (drop & reseed for MVP)
- Exit criteria: ERD committed, interface contracts agreed

## Phase 1 – Database & Migrations
- Create migrations for new tables with indexes and per-session sequences (`chat_sessions.seq_name`)
- `chat_sessions` columns: `id`, `initiator_id`, `peer_id`, `agent_id?`, `kind`, `status`, `metadata`, `seq_name`, `last_message_id`, `last_message_at`, timestamps
- `chat_messages` columns: `id`, `session_id`, `sender_id`, `seq`, `kind`, `content` (JSONB), `metadata`, `shard_key`, timestamps
- `agent_endpoints`, `agent_delivery_logs` tables per blueprint
- Exit criteria: `mix ecto.migrate` succeeds on fresh DB with schema matching design

## Phase 2 – Context Layer APIs
- Contexts: `Fleetlm.Participants`, `Fleetlm.Agents`, `Fleetlm.Sessions`
- Session creation enforces exactly two participants, allocates per-session sequence, inserts seed row
- Message append uses single insert returning `seq` via stored sequence
- Replace `Fleetlm.Chat` with new API; add temporary compatibility wrappers if needed
- Exit criteria: Context unit tests cover session create/list and message append

## Phase 3 – Runtime & Caching
- Implement `SessionServer` keyed by `session_id` (manages ordering, caching)
- Update Cachex caches (`session_tails`, `inbox_snapshots`) to use `session_id`
- Inbox runtime aggregates sessions per participant from `chat_sessions`
- Telemetry hooks for session lifecycle and message append
- Exit criteria: Supervision tree boots, runtime tests green

## Phase 4 – Webhook Agent Dispatcher
- `AgentDispatcher` consumes message events where `agent_id` present and sender != agent
- Deliver via `Req`, record outcomes in `agent_delivery_logs`, implement retry/backoff
- Emit telemetry + PromEx metrics for delivery success/failure
- Exit criteria: Integration tests simulate success/failure, logs captured

## Phase 5 – External Interfaces (REST + Channels + CLI)
- REST: `/api/sessions` CRUD (create/list), `/api/sessions/:id/messages` (list/append)
- WebSocket channels: topics `session:{session_id}` and `participant_inbox:{participant_id}`
- Update CLI + tests to operate on session IDs and `seq`
- Remove legacy DM endpoints
- Exit criteria: Controller/channel tests pass, CLI smoke test works

## Phase 6 – Admin LiveView & Observability
- LiveViews for agent management (index/show/edit) and delivery logs
- Session explorer (read-only) to inspect timelines for support
- Extend PromEx dashboards with session + delivery metrics
- Exit criteria: LiveView tests passing, dashboards compile

## Phase 7 – Cleanup & Post-Migration Tasks
- Remove deprecated `dm_*` modules and caches
- Drop compatibility shims and unused config
- Update docs (README/AGENTS) to reflect new architecture
- Run `mix precommit`
- Exit criteria: repo clean, docs updated, precommit green

## Validation Checklist (ongoing)
- `mix test`
- `mix ecto.migrate`
- `mix precommit` before delivery
- Manual webhook smoke test against stub endpoint

