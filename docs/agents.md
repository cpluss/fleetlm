---
title: Agent Webhooks
sidebar_position: 2
---

# Agent Webhooks

FleetLM talks to agents through simple HTTP webhooks. Register the endpoint once, then respond with newline-delimited JSON whenever a session message arrives.

## Register an agent

```bash
POST /api/agents
Content-Type: application/json

{
  "agent": {
    "id": "my-agent",
    "name": "My Agent",
    "origin_url": "https://agent.example.com",
    "webhook_path": "/webhook",
    "message_history_mode": "tail",
    "message_history_limit": 20,
    "timeout_ms": 30000,
    "headers": {
      "X-API-Key": "secret"
    }
  }
}
```

- `message_history_mode`: `tail` (default), `last`, or `entire`
- `message_history_limit`: positive integer (used by `tail`)
- `timeout_ms`: how long FleetLM waits for a response
- `headers`: optional map sent with every webhook request

## Webhook request payload

```json
{
  "session_id": "01HZXAMPLE12345",
  "agent_id": "my-agent",
  "user_id": "alice",
  "messages": [
    {
      "seq": 1,
      "sender_id": "alice",
      "kind": "text",
      "content": { "text": "Hello!" },
      "inserted_at": "2024-10-03T12:00:00Z"
    }
  ]
}
```

Session metadata is stored internally but not forwarded to the webhook.

### Message history modes

| Mode   | Behaviour                                   |
|--------|---------------------------------------------|
| `tail` | Last N messages (N = `message_history_limit`)|
| `last` | Most recent message, `limit` must stay > 0   |
| `entire` | Full conversation; limit must stay > 0    |

## Respond with JSONL

Reply using `200` status and newline-delimited JSON. Every line becomes a message appended to the session.

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"kind": "text", "content": {"text": "Thinking..."}}
{"kind": "text", "content": {"text": "Here we go!"}}
```

Each object must include:

- `kind`: message type (`text`, `tool_call`, etc.)
- `content`: JSON payload (structure defined by you)
- `metadata` (optional): stored alongside the message

Malformed lines are skipped and surfaced via telemetry.
