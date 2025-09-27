# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Setup and Dependencies
- `mix setup` - Complete setup including deps, database, and assets
- `mix deps.get` - Install Elixir dependencies

### Development
- `mix phx.server` - Start development server
- `mix test` - Run tests
- `mix test test/path/to/specific_test.exs` - Run specific test file
- `mix test --failed` - Re-run only failed tests

### Code Quality
- `mix precommit` - Comprehensive pre-commit check that runs compilation with warnings as errors, deps cleanup, formatting, and tests
- `mix format` - Format code
- `mix compile --warning-as-errors` - Compile with strict warnings

### Database
- `mix ecto.setup` - Create, migrate database and run seeds
- `mix ecto.create` - Create database
- `mix ecto.migrate` - Run migrations
- `mix ecto.reset` - Drop and recreate database

### Assets
- `mix assets.build` - Build frontend assets (Tailwind CSS + esbuild)
- `mix assets.deploy` - Build and minify assets for production

## Architecture Overview

FleetLM is a real-time chat/messaging runtime built with Phoenix, designed for scalable chat applications supporting humans and AI agents.

### Core Components

**Session Runtime (`lib/fleetlm/runtime/`)**
- `Fleetlm.Runtime.Supervisor` – Root supervisor booting caches, registries, and dynamic supervisors for the runtime tree.
- `Fleetlm.Runtime.SessionSupervisor` / `SessionServer` – Per-session GenServer processes that broadcast updates, maintain hot tails, and serve channel joins.
- `Fleetlm.Runtime.InboxSupervisor` / `InboxServer` – Per-participant processes that materialize inbox snapshots and manage unread counts.
- `Fleetlm.Runtime.Cache` / `CacheSupervisor` – Cachex-backed stores for session tails and inbox snapshots.
- `Fleetlm.Runtime.Gateway` – Stateless boundary used by HTTP/WS entry points; the swap target for Phase 3 shard RPC.

**Persistence (`lib/fleetlm/sessions.ex` + schemas)**
- `Fleetlm.Conversation` – Ecto context for chat sessions and messages, orchestrating persistence plus runtime fan-out hooks.
- `Fleetlm.Conversation.ChatSession` / `ChatMessage` – Schemas backing the session/message tables.

**Real-time Communication (`lib/fleetlm_web/channels/`)**
- `SessionChannel` – WebSocket channel for per-session messaging; delegates to the runtime gateway + session servers.
- `InboxChannel` – Participant inbox stream powered by inbox servers and Cachex snapshots.
- Uses Phoenix PubSub for message broadcasting across nodes.

**Key Architecture Patterns**
- Each active session runs as a dedicated GenServer process for isolation and concurrency.
- Registry-based process discovery (`Fleetlm.Runtime.SessionRegistry` / `InboxRegistry`).
- Cachex-assisted fan-out for low-latency session tails and inbox data.
- Postgres persistence with Ecto for all data.

### Data Flow
1. Messages arrive via WebSocket (`SessionChannel`) or REST controllers.
2. Entry points call `Fleetlm.Runtime.Gateway` which proxies to `Fleetlm.Conversation`.
3. Persistence occurs inside `Fleetlm.Conversation.append_message/2` (optimized SQL path).
4. The runtime `SessionServer` is notified, caches the message tail, and broadcasts via Phoenix PubSub.
5. Inbox servers receive updates to refresh per-participant snapshots and unread counts.

### Database Schema
- ULIDs for primary keys across sessions and messages.
- Sessions store initiator/peer identifiers, metadata, and last-read timestamps.
- Messages belong to sessions, capture sender metadata, and are sharded by `shard_key` for future distribution work.

## Testing

- Phoenix LiveView testing with `Phoenix.LiveViewTest`
- Channel testing with `Phoenix.ChannelTest`
- Use `test/support/` helpers: `ConnCase`, `ChannelCase`, `DataCase`
- Integration tests in `test/fleetlm_web/channels/messaging_flow_test.exs`

## Important Notes

- Always run `mix precommit` before committing changes
- Use the `:req` library for HTTP requests (already included)
- Follow existing patterns in AGENTS.md for Phoenix/Elixir conventions
- Session processes are `:temporary` restart - they terminate when no longer needed
- WebSocket authentication handled via `user_socket.ex` (JWT-based)
