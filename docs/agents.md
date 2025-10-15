---
title: Agent Webhooks
sidebar_position: 2
---

# Agent Webhooks

FleetLM talks to agents through simple HTTP webhooks. Register the endpoint once, then stream [AI SDK UI message chunks](https://sdk.vercel.ai/docs/stream-protocol) (newline-delimited JSON) whenever a session message arrives. FleetLM forwards every chunk to connected clients in real time and compacts the full stream into a single assistant message when it finishes.

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
    "debounce_window_ms": 500,
    "headers": {
      "X-API-Key": "secret"
    }
  }
}
```

- `message_history_mode`: `tail` (default), `last`, or `entire`
- `message_history_limit`: positive integer (used by `tail`)
- `timeout_ms`: how long FleetLM waits for a response
- `debounce_window_ms`: debounce window in milliseconds (default: 500)
- `headers`: optional map sent with every webhook request

## Webhook Debouncing

FleetLM batches rapid message bursts using a debounce mechanism to reduce agent load and improve efficiency:

- When a user sends a message, FleetLM schedules a webhook dispatch after `debounce_window_ms`
- If another message arrives before the timer fires, the timer resets
- When the timer finally expires, the agent receives **all accumulated messages** in a single webhook call

**Example:** User sends 10 messages with 300ms gaps, `debounce_window_ms = 500`:
- Messages 1-10 arrive over 3 seconds
- Each message resets the 500ms timer
- After the last message, timer fires after 500ms
- Agent receives **1 webhook** with all 10 messages batched together

**Benefits:**
- Reduces webhook calls (10 messages → 1 webhook)
- Mirrors natural human ↔ agent interaction patterns
- Configurable per-agent for different use cases

**Tuning:**
- `debounce_window_ms: 0` — Immediate dispatch (no batching)
- `debounce_window_ms: 500` — Default, good for most cases
- `debounce_window_ms: 2000` — High batching for slow-typing users

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

## Respond with [AI SDK JSONL](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol)

Reply with status `200` and newline-delimited JSON. Each line must be a valid **UI message chunk**. FleetLM validates the payload, broadcasts it to WebSocket subscribers via `stream_chunk`, and only persists a message when it receives a terminal chunk (`finish` or `abort`).

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"type":"start","messageId":"msg_123"}
{"type":"text-start","id":"part_1"}
{"type":"text-delta","id":"part_1","delta":"Thinking"}
{"type":"text-delta","id":"part_1","delta":"..."}
{"type":"text-end","id":"part_1"}
{"type":"finish","messageMetadata":{"latency_ms": 1800}}
```

Common chunk types include:

- `start`, `finish`, `abort` – lifecycle markers for the message.
- `text-*`, `reasoning-*` – streaming natural language and reasoning traces.
- `tool-*` – tool call arguments/results (static and dynamic tools).
- `data-*`, `file`, `source-*` – structured attachments such as charts or citations.

FleetLM stores the final, compacted assistant message with `kind: "assistant"` and the collected `parts` array. Any chunk the parser cannot recognise results in telemetry (`:invalid_json`, `:missing_type`) and is dropped.
