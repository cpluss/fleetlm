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

**Chat System (`lib/fleetlm/chat/`)**
- `Chat` - Main context module providing high-level API for messaging operations
- `ThreadServer` - GenServer managing individual thread state and message caching (40 message limit)
- `ThreadSupervisor` - Dynamic supervisor for thread processes
- Thread data models: `Thread`, `Participant`, `Message`

**Real-time Communication (`lib/fleetlm_web/channels/`)**
- `ThreadChannel` - WebSocket channel for real-time messaging in threads
- `ParticipantChannel` - Channel for participant-specific events and updates
- Uses Phoenix PubSub for message broadcasting across nodes

**Key Architecture Patterns**
- Each thread runs as a separate GenServer process for isolation and concurrency
- Registry-based process discovery (`Fleetlm.Chat.ThreadRegistry`)
- Message sharding using `:erlang.phash2/2` for horizontal scaling
- Per-thread message caching (last 40 messages) for performance
- Postgres persistence with Ecto for all data

### Data Flow
1. Messages sent via WebSocket to `ThreadChannel`
2. Channel calls `Chat.dispatch_message/2`
3. Ensures `ThreadServer` process exists for the thread
4. `ThreadServer` persists message via `Chat.send_message/2`
5. Broadcasts to thread participants via Phoenix PubSub
6. Updates in-memory cache and participant metadata

### Thread Types
- `dm` - Direct messages between two participants (requires `dm_key`)
- `room` - Group conversations
- `broadcast` - One-to-many messaging

### Database Schema
- Binary UUIDs for all primary keys
- Threads have participants (many-to-many with roles)
- Messages belong to threads and have senders
- Read cursors tracked per participant for unread counts

## Testing

- Phoenix LiveView testing with `Phoenix.LiveViewTest`
- Channel testing with `Phoenix.ChannelTest`
- Use `test/support/` helpers: `ConnCase`, `ChannelCase`, `DataCase`
- Integration tests in `test/fleetlm_web/channels/messaging_flow_test.exs`

## Important Notes

- Always run `mix precommit` before committing changes
- Use the `:req` library for HTTP requests (already included)
- Follow existing patterns in AGENTS.md for Phoenix/Elixir conventions
- Thread processes are `:temporary` restart - they terminate when no longer needed
- WebSocket authentication handled via `user_socket.ex` (JWT-based)