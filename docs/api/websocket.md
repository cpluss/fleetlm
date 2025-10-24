---
title: Websocket
sidebar_position: 2
---

# Websocket API

Fastpaca exposes a backend-only websocket for watching conversation updates in near real-time.  Use it to trigger compaction workers, fan out updates to other services, or maintain UI state via your own gateway.

Endpoint:

```
ws://HOST/v1/conversations/:id/stream
```

## Connection parameters

| Query parameter | Description |
| --- | --- |
| `cursor` (optional) | The last version you processed.  Pass `0` to receive everything from the beginning. |
| `includeEvents` (default `true`) | Set to `false` if you only care about window/compaction updates. |

Example:

```
ws://localhost:4000/v1/conversations/support-123/stream?cursor=120
```

If authentication is enabled, include the API key via the `Authorization` header (`Bearer …`).

## Message format

All messages are JSON objects with `type` and `version`.  Version numbers are strictly increasing.

### Event notifications

```json
{
  "type": "event",
  "version": 121,
  "seq": 121,
  "event": {
    "role": "user",
    "parts": [{ "type": "text", "text": "Any updates?" }],
    "inserted_at": "2025-01-24T12:00:00Z"
  }
}
```

Sent whenever a new event is appended.

### Window invalidations

```json
{
  "type": "window",
  "version": 121,
  "needs_compaction": false,
  "used_tokens": 512340
}
```

Indicates that the cached window should be refreshed via `GET /window`.

### Compaction acknowledgements

```json
{
  "type": "compaction",
  "version": 122,
  "range": { "from_seq": 1, "to_seq": 80 }
}
```

Emitted after a successful `/compact` call.

### Tombstone notice

```json
{ "type": "tombstoned", "version": 0 }
```

The conversation has been deleted.  The server closes the connection after sending this message.

### Snapshot reset

```json
{ "type": "reset", "version": 200 }
```

The snapshot was rebuilt (e.g., after a manual repair).  Clients should discard cached state and fetch a fresh window.

## Heartbeats & timeouts

- The server sends a `{"type":"ping"}` heartbeat every 30 seconds.  
- Clients should respond with `{"type":"pong"}` to keep the connection alive.  
- Idle connections without heartbeats for 90 seconds are closed.

## Reconnect logic

1. Keep track of the highest `version` you've processed.  
2. On reconnect, pass that value as `cursor`.  
3. If the server responds with `{"type":"gap","expected":...,"actual":...}` immediately fetch the missing events via `GET /events` and resume with the returned `version`.

## Limits

- The websocket is intended for backend-to-backend use.  Do not expose it directly to browsers.  
- To mirror updates to clients, fan out through your own gateway (e.g., WebSocket, SSE, or Pub/Sub).  
- Maximum concurrent connections per node are configurable; defaults to 512.
