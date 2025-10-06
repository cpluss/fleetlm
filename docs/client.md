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
    "sender_id": "alice",
    "kind": "text",
    "content": {"text": "Hello"}
  }'
```

### Fetch messages

```bash
curl http://localhost:4000/api/sessions/{session_id}/messages?after_seq=0&limit=50
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
  console.log(`${msg.sender_id}:`, msg.content);
  lastSeq = Math.max(lastSeq, msg.seq);
});

channel.push("send", {
  content: {
    kind: "text",
    content: { text: "Hello!" }
  }
});
```

Reconnect with the same `user_id` and pass the most recent `last_seq` so FleetLM can replay anything you missed.
