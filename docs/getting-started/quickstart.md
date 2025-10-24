---
title: Quick Start
sidebar_position: 1
---

# Quick Start

Spin up FleetLM with Docker, run the demo webhook, and send your first message. When you are done, explore the [Next.js example](./nextjs-example.md) for a richer UI + webhook combo.

## Prerequisites

- Docker Desktop or Docker Engine (Compose v2)

## 1. Start FleetLM

Create a working directory and download the published Compose file:

```bash
mkdir fleetlm-demo
cd fleetlm-demo
curl -LO https://raw.githubusercontent.com/cpluss/fleetlm/main/docker-compose.yml
```

Launch the stack (FleetLM + Postgres):

```bash
docker compose up -d
```

The API and WebSocket endpoints are available at `http://localhost:4000` and `ws://localhost:4000/socket`. Logs stream with `docker compose logs -f app`.

## 2. Run the echo webhook (netcat)

Open a second terminal on the host machine and run a tiny echo server. It returns the same AI SDK JSONL chunks FleetLM expects:

```bash
while true; do \
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"type":"text-start","id":"part_1"}\n{"type":"text-delta","id":"part_1","delta":"ack"}\n{"type":"text-end","id":"part_1"}\n{"type":"finish"}\n'; \
  nc -l -p 3000 -q 1; \
done
```

> Docker Desktop exposes the host as `host.docker.internal`. On Linux you may need to add `extra_hosts: ["host.docker.internal:host-gateway"]` to the Compose file or substitute the host IP address when registering the agent.

## 3. Register the agent

Tell FleetLM where to reach the echo server running on the host:

```bash
curl -X POST http://localhost:4000/api/agents \
  -H "Content-Type: application/json" \
  -d '{
    "agent": {
      "id": "bench-echo-agent",
      "name": "Bench Echo Agent",
      "origin_url": "http://host.docker.internal:3000",
      "webhook_path": "/webhook",
      "context": {
        "strategy": "last_n",
        "config": {"limit": 10}
      },
      "timeout_ms": 30000,
      "debounce_window_ms": 250,
      "status": "enabled"
    }
  }'
```

FleetLM now knows how to reach your agent. The full webhook contract is documented in [Webhooks](../integrations/agents.md).

## 4. Create a session

Sessions pair a user with an agent. Keep the returned `id`. You will use it in later calls.

```bash
curl -X POST http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "alice",
    "agent_id": "bench-echo-agent"
  }'
```

## 5. Send a message

Replace `{session_id}` with the value from the previous step.

```bash
curl -X POST http://localhost:4000/api/sessions/{session_id}/messages \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "alice",
    "kind": "text",
    "content": {"text": "Hello FleetLM!"}
  }'
```

FleetLM persists the user message, invokes the webhook, and streams agent chunks back to connected clients. When the webhook emits `finish`, FleetLM stores the compacted assistant message.

## 6. Read the conversation

```bash
curl http://localhost:4000/api/sessions/{session_id}/messages
```

You will see both the user message and the assistant response produced by the demo webhook.

## Next Steps

- Try the interactive terminal client in the demo (`npm run client`) or the full [Next.js example](./nextjs-example.md).
- Learn more about the webhook lifecycle in [Webhooks](../integrations/agents.md).
- Understand the mental model behind sessions, agents, and compaction in [Concepts](../core/concepts.md).
