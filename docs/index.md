---
title: FleetLM
slug: /
sidebar_position: 1
---

# FleetLM

![](./img/high-level-clustered.png)

FleetLM is production-ready infrastructure for human ↔ agent conversations. Drop it in front of any HTTP-compatible agent and you immediately get:

- **Framework freedom** – agents are plain webhooks, so keep your stack (FastAPI, Express, Go, etc.).
- **Real-time delivery** – Phoenix Channels stream every token; REST polling stays in sync via sequence numbers.
- **Durable ordering** – append-only logs, at-least-once semantics, and replay on reconnect.
- **Horizontal scale from day one** – libcluster shards sessions across nodes; Postgres is the durable store.

See [Architecture](./architecture.md) for the full breakdown of session servers, inbox feeds, and storage tiers.

## What you need

1. **Run FleetLM** – use Docker Compose to launch the Phoenix release (`SECRET_KEY_BASE`, `DATABASE_URL`).
2. **Register an agent** – expose a POST endpoint that accepts JSON payloads and streams JSONL back.
3. **Create a session** – pair a user id with an agent id.
4. **Send messages** – use REST or WebSockets; FleetLM handles ordering and delivery.

## Docs

- [Quick Start](./quickstart.md) – clone the repo, run Compose, send your first message.
- [Agent Webhooks](./agents.md) – payload schema, response format, registration knobs.
- [Clients](./client.md) – REST endpoints and Phoenix Channel usage.
- [Deployment](./deployment.md) – environment variables and scaling notes.
- [Architecture](./architecture.md) – how FleetLM routes traffic, stores messages, and handles failover.
