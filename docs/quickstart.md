---
title: Quick Start
sidebar_position: 1
---

# Quick Start

Spin up FleetLM locally, register an agent webhook, and send your first message.

## 1. Run the stack

Checkout the repository

```bash
git clone https://github.com/cpluss/fleetlm.git
cd fleetlm
```

Run the test stack using docker

```bash
docker compose up --build
```

The API and WebSocket endpoints are available at `http://localhost:4000` and `ws://localhost:4000/socket`.

## 2. Register an agent

Tell FleetLM where your agent lives.

```bash
curl -X POST http://localhost:4000/api/agents \
  -H "Content-Type: application/json" \
  -d '{
    "agent": {
      "id": "demo-agent",
      "name": "Demo Agent",
      "origin_url": "http://localhost:3000",
      "webhook_path": "/webhook",
      "message_history_mode": "tail",
      "message_history_limit": 10,
      "timeout_ms": 30000,
      "status": "enabled"
    }
  }'
```

Your webhook will receive the session id, agent id, user id, and the most recent messages. See [Agent Webhooks](./agents.md) for the exact format.

## 3. Create a session

Every session need to be created upfront so we know what agent to connect it to.

```bash
curl -X POST http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "session": {
      "user_id": "alice",
      "agent_id": "demo-agent"
    }
  }'
```

Save the `id` from the response. All future REST and WebSocket calls reference it.

## 4. Send a message

Sending a message using the REST API is easy, and follows a flexible format that mirror many popular platforms (e.g. OpenAI) today.

```bash
curl -X POST http://localhost:4000/api/sessions/{session_id}/messages \
  -H "Content-Type: application/json" \
  -d '{
    "sender_id": "alice",
    "kind": "text",
    "content": {"text": "Hello!"}
  }'
```

FleetLM stores the user message, invokes your agent webhook, and streams each JSONL line your agent returns into the session.

## 5. Read the conversation

```bash
curl http://localhost:4000/api/sessions/{session_id}/messages
```

You should see the user message and any responses produced by your agent. For real-time streaming or cursor management, continue with [Clients](./client.md).
