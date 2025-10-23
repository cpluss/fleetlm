---
title: Clients
sidebar_position: 2
---

# Clients

Use WebSockets for realtime streaming (recommended) and REST for secondary workflows like pagination or backfills. The official TypeScript client `@fleetlm/client` wraps the WebSocket flow with reconnection, cursors, and typed events.

## What the Client Does

- Attach the correct `user_id` to the connection (FleetLM stays agnostic to how you authenticate).
- Maintain a `last_seq` cursor so reconnects replay missed messages.
- Render live `stream_chunk` events (tokens before completion) and replace them with the persisted assistant message on `finish`.
- Decide when to fetch older history or switch sessions (Inbox vs Session channels).

FleetLM guarantees ordering and delivery so your UI can focus on experience. See the [Next.js example](../getting-started/nextjs-example.md) for a full-stack walkthrough that pairs the WebSocket client with a webhook in the same project.

## WebSocket streaming (preferred)

Install the SDK:

```bash
npm install @fleetlm/client
```

Then connect and send messages:

```javascript
import { FleetLMClient } from "@fleetlm/client";

const client = new FleetLMClient({
  userId: "alice",
  agentId: "demo-agent",
  sessionId: "01K6GR2EV9Z7PSMEVVJ5M954CH" // optional: provide or let the SDK create one
});

client.on("message", (msg) => {
  console.log("persisted message", msg);
});

client.on("chunk", ({ chunk, agentId }) => {
  console.log("stream chunk from", agentId, chunk);
});

await client.connect();
await client.send({ kind: "text", content: { text: "Hello FleetLM!" } });
```

Under the hood the SDK joins `session:{session_id}` via Phoenix Channels, keeps `last_seq` in sync, and exposes helper methods for pagination. If you prefer to wire it yourself, the bare Phoenix client example is below.

## REST basics

Use these endpoints for scripting, migrations, or pagination-heavy interfaces. WebSockets remain the primary path for realtime experiences.

### Send a message

```bash
curl -X POST http://localhost:4000/api/sessions/{session_id}/messages \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "alice",
    "kind": "text",
    "content": {"text": "Hello"}
  }'

# For agent authored messages, provide `agent_id` instead of `user_id`.
```

### Fetch messages

```bash
curl http://localhost:4000/api/sessions/{session_id}/messages?after_seq=0&limit=50
```

Assistant responses are stored with `kind: "assistant"` and a structured payload:

```json
{
  "seq": 2,
  "kind": "assistant",
  "content": {
    "id": "msg_123",
    "role": "assistant",
    "parts": [
      { "type": "text", "text": "Thinking...", "state": "done" }
    ]
  },
  "metadata": { "termination": "finish", "latency_ms": 1800 }
}
```

### Mark messages as read

```bash
curl -X POST http://localhost:4000/api/sessions/{session_id}/read \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "alice",
    "last_seq": 42
  }'
```

## WebSocket streaming (bare Phoenix client)

```javascript
import { Socket } from "phoenix";

let lastSeq = 0;

const socket = new Socket("ws://localhost:4000/socket", {
  params: { user_id: "alice" }
});

socket.connect();

const channel = socket.channel(`session:${sessionId}`, { last_seq: lastSeq });

channel.join()
  .receive("ok", ({ messages }) => {
    if (messages.length > 0) {
      lastSeq = messages[messages.length - 1].seq;
    }
  })
  .receive("error", (err) => console.error("join failed", err));

channel.on("message", (msg) => {
  if (msg.kind === "assistant") {
    console.log(`${msg.sender_id} parts:`, msg.content.parts);
  } else {
    console.log(`${msg.sender_id}:`, msg.content);
  }
  lastSeq = Math.max(lastSeq, msg.seq);
});

channel.on("stream_chunk", ({ chunk, agent_id }) => {
  // Render incremental updates before the message is persisted
  console.debug(`chunk from ${agent_id}:`, chunk);
});

channel.push("send", {
  content: {
    kind: "text",
    content: { text: "Hello!" }
  }
});
```

Reconnect with the same `user_id` and pass the most recent `last_seq` so FleetLM can replay anything you missed. Live chunks are not replayed-clients should reconstruct UI from the persisted assistant message delivered via `message` after a `finish` chunk.
