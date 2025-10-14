---
title: Clients
sidebar_position: 3
---

# Clients

Use the REST API for simple workflows or websockets for realtime streaming.

## REST basics

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

## WebSocket streaming

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

Reconnect with the same `user_id` and pass the most recent `last_seq` so FleetLM can replay anything you missed. Live chunks are not replayed—clients should reconstruct UI from the persisted assistant message delivered via `message` after a `finish` chunk.
