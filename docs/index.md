---
title: FleetLM
slug: /
sidebar_position: 1
---

# FleetLM

![](./img/high-level-clustered.png)

FleetLM is drop-in infrastructure for human ↔ agent conversations. Drop it in front of any HTTP-compatible agent and you immediately get:

- **Framework freedom** – agents are plain webhooks, so keep your stack (FastAPI, Express, Go, etc.).
- **Real-time delivery** – websockets stream every message; REST polling stays in sync via sequence numbers.
- **Durable ordering** – append-only logs, at-least-once semantics, and replay on reconnect.
- **Horizontal scale from day one** – shard sessions across nodes; use Postgres as persistent backend.

See [Architecture](./architecture.md) for the full breakdown of session servers, inbox feeds, and storage tiers.

## What you need

1. **Run FleetLM** – use Docker Compose to launch locally.
2. **Register an agent** – expose an endpoint that accepts JSON payloads and streams LLM messages back as JSONL.
3. **Create a session** – pair a user id with an agent id.
4. **Send messages** – use REST or WebSockets; FleetLM handles ordering and delivery.

## Docs

- [Quick Start](./quickstart.md) – clone the repo, run Compose, send your first message.
- [Agent Webhooks](./agents.md) – payload schema, response format, registration knobs.
- [Clients](./client.md) – REST endpoints and Phoenix Channel usage.
- [Deployment](./deployment.md) – environment variables and scaling notes.
- [Architecture](./architecture.md) – how FleetLM routes traffic, stores messages, and handles failover.
