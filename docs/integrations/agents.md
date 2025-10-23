---
title: Webhooks
sidebar_position: 1
---

# Webhooks

FleetLM delivers messages to your agent through HTTP POST requests. You register the webhook once per agent, then FleetLM takes care of batching, retries, chunk streaming, and compaction triggers. Use the quick start below for the fastest integration. Detailed guidance follows in later sections.

## Quick Start

1. **Create the webhook endpoint**

   ```ts
   export async function POST(req: Request) {
     const payload = await req.json();
     const { messages } = payload;

     const stream = streamText({
       model: openai("gpt-4o-mini"),
       messages: [
         { role: "system", content: "You are a helpful assistant." },
         ...messages
       ]
     });

     return stream.toUIMessageStream();
   }
   ```

2. **Register the agent**

   ```bash
   curl -X POST http://localhost:4000/api/agents \
     -H "Content-Type: application/json" \
     -d @agent.json
   ```

   `agent.json`:

   ```json
   {
     "agent": {
       "id": "support-bot",
       "name": "Support Bot",
       "origin_url": "https://agent.example.com",
       "webhook_path": "/webhook",
       "message_history_mode": "tail",
       "message_history_limit": 50,
       "timeout_ms": 30000,
       "debounce_window_ms": 500
     }
   }
   ```

3. **Handle compaction (optional)**

   ```ts
   export async function POST(req: Request) {
     const payload = await req.json();

     const summary = await generateText({
       model: openai("gpt-4o-mini"),
       messages: [
         { role: "system", content: "Summarize this conversation." },
         ...payload.messages
       ]
     });

     return Response.json({
       compacted: [{ role: "assistant", content: summary.text }]
     });
   }
   ```

## Why Register an Agent?

An agent definition tells FleetLM:

- **Where to send work** - `origin_url` + `webhook_path` resolve to your HTTP endpoint.
- **How much history to include** - `message_history_mode` and `message_history_limit` define the transcript slice sent with each request.
- **How to protect the agent** - `timeout_ms`, `debounce_window_ms`, and optional headers let you tune retries, batching, and auth.
- **When to compact** - optional compaction settings give FleetLM the webhook that replaces long transcripts with summaries.

Without registration FleetLM has nowhere to forward messages; every session must reference a registered agent.

## End-to-End Flow

1. **User sends a message** via REST or WebSocket.
2. **FleetLM persists the message** with a new sequence number.
3. **Debounce window opens** - FleetLM waits `debounce_window_ms` to batch additional user messages.
4. **Webhook request is issued** - FleetLM POSTs the transcript slice to your agent endpoint.
5. **You stream AI SDK chunks** - every chunk is forwarded to subscribed clients immediately.
6. **Terminal chunk arrives** - FleetLM collapses the streamed parts into a single assistant message and queues the next batch if pending.
7. **Compaction triggers (optional)** - when token budgets are exceeded, FleetLM invokes your compaction webhook before resuming catch-up work.

## Agent Configuration Reference

| Field | Required | Purpose | Default |
| --- | --- | --- | --- |
| `id` | ✅ | Unique identifier referenced by sessions | - |
| `name` | ✅ | Human-friendly label | - |
| `origin_url` | ✅ | Base URL for webhook calls (protocol + host) | - |
| `webhook_path` | ✅ | Path appended to `origin_url` | `/webhook` |
| `message_history_mode` | ✅ | Transcript slice sent with each webhook | `"tail"` |
| `message_history_limit` | ✅ | Number of messages when mode is `tail`/`last` | `50` |
| `timeout_ms` | ✅ | HTTP timeout per request | `30000` |
| `debounce_window_ms` | ✅ | Delay before dispatch to batch bursts | `500` |
| `headers` | Optional | Extra headers per request (API keys, signatures) | `{}` |
| `compaction_enabled` | Optional | Turn on automatic compaction | `false` |
| `compaction_token_budget` | Optional | Token budget before compaction triggers | `50000` |
| `compaction_trigger_ratio` | Optional | Fraction of budget that triggers compaction | `0.7` |
| `compaction_webhook_url` | Optional | Endpoint invoked when compacting | `nil` |

Agents are stored in Postgres and cached in-memory. Update or delete them via the same REST API when needed.

> Most teams leave `message_history_mode` as `"tail"` and rely on compaction to keep transcripts manageable. History modes remain for compatibility but are rarely customised.

## Request Payload Shape

```json
{
  "session_id": "01HXZAMPLE12345",
  "agent_id": "support-bot",
  "user_id": "alice",
  "messages": [
    {
      "seq": 42,
      "sender_id": "alice",
      "kind": "text",
      "content": { "text": "Hello!" },
      "inserted_at": "2024-10-03T12:00:00Z"
    }
  ]
}
```

- `messages` honours the history mode:  
  | Mode | Behaviour |
  | --- | --- |
  | `tail` | Last N messages (`message_history_limit`) |
  | `last` | Only the most recent message |
  | `entire` | Full conversation (limit must stay > 0) |
- FleetLM omits internal metadata from the payload to keep your webhook stateless.

## Streaming Responses (AI SDK JSONL)

FleetLM expects newline-delimited JSON that follows the [AI SDK UI message protocol](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol). Each chunk is validated and forwarded to clients in real time.

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"type":"start","messageId":"msg_123"}
{"type":"text-start","id":"part_1"}
{"type":"text-delta","id":"part_1","delta":"Thinking"}
{"type":"text-end","id":"part_1"}
{"type":"finish","message":{"id":"msg_123","role":"assistant","parts":[{"type":"text","text":"Thinking","state":"done"}]}}
```

Key chunk families:

- `start`, `finish`, `abort` - lifecycle events for the streamed message
- `text-*`, `reasoning-*` - natural language and reasoning traces
- `tool-*` - tool inputs/outputs for dynamic agent workflows
- `data-*`, `file`, `source-*` - structured attachments

FleetLM stores the final assistant message assembled at `finish` (or `abort`) and drops malformed chunks with telemetry for debugging.

## Debouncing Behaviour

- FleetLM delays webhook dispatch by `debounce_window_ms` to batch rapid bursts.
- New user messages arriving within the window reset the timer.
- When it fires, the agent receives one webhook containing all pending messages.

**Tuning examples:**

- `debounce_window_ms = 0` - fire immediately (no batching).
- `debounce_window_ms = 250` - default; smooths fast typers without noticeable lag.
- `debounce_window_ms = 2000` - heavy batching for telemetry-rich or tool-heavy workloads.

## Compaction Lifecycle

1. FleetLM tracks `tokens_since_summary` per conversation using your configured budget.
2. When `tokens >= budget * trigger_ratio`, FleetLM transitions the conversation to `:compacting`.
3. Pending user messages are queued until compaction finishes.
4. FleetLM POSTs the compaction webhook with the full transcript slice and metadata.
5. You return a compacted transcript (summary, key facts, etc.). FleetLM persists it and resets the token counter.
6. Queued messages resume with a fresh catch-up epoch.

Compaction keeps live context lean while the immutable Raft log still contains every historical message for audits or analytics. See the [Architecture](../core/architecture.md#compaction) section for internal details.

## Integration Tips

- **Auth** - use static headers or signed tokens. FleetLM does not store secrets; it forwards what you configure.
- **Retries** - FleetLM retries transient failures. Ensure your webhook can handle duplicate deliveries (idempotent processing).
- **Metadata** - use `finish` chunk metadata to attach token usage, latency, or trace IDs. FleetLM persists it alongside the assistant message.
- **Testing** - leverage the [Next.js example](../getting-started/nextjs-example.md) to iterate quickly with live streaming and compaction hooks.

Webhooks are the contract between your agent logic and FleetLM’s runtime. Keep them stateless, idempotent, and streaming-friendly, and FleetLM will take care of ordering, delivery, and context management.
