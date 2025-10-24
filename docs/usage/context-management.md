---
title: Context Management
sidebar_position: 3
---

# Context Management

Fastpaca keeps two representations of every conversation:

1. **Log** – immutable events with sequence numbers.  
2. **Snapshot** – a compacted summary + live tail used to build the context window.

This page explains how token budgets, strategies, and compaction triggers work together.

---

## Token budgets

- Defined per conversation (`token_budget`).  
- Expressed in tokens, not messages.  Budgets up to **1,000,000 tokens** are supported today.  
- Every call to `/window` enforces the budget.  If you ask for more than the budget, Fastpaca returns the largest slice that fits and flags `needs_compaction`.

### Trigger thresholds

- `needs_compaction` flips to `true` when the snapshot plus tail exceed **70%** of the budget.  
- The 70% threshold leaves headroom for the next user turn and any system prompts you prepend.  
- You can override the threshold per conversation by setting `policy.trigger_ratio` (e.g., `0.6` for 60%).

---

## Strategies

Strategies define how the snapshot evolves as new events arrive. They run inline inside the Raft state machine and must be deterministic and fast.

### Built-in strategies

| Strategy | Description | Typical use |
| --- | --- | --- |
| `last_n` | Maintain a FIFO queue of the most recent events, trimming older ones.  Respects both item count (`limit`) and token budget. | Short-lived assistants where the latest turns matter most. |
| `strip_tool_results` | Drop `tool_result` events, then behave like `last_n`.  Keeps prompts terse while preserving tool call metadata. | Agents that produce large tool outputs (retrieval, code execution). |
| `budget` | Keep all events in the tail, only flag `needs_compaction` when the budget threshold is crossed. | Use with your own summariser to replace history in larger chunks. |

All strategies share a `max_tokens` configuration which defaults to the conversation budget if omitted.

### Custom strategies

You can register additional strategies in the Fastpaca server configuration. A strategy module implements:

```elixir
@callback append_message(snapshot | nil, event, config, opts) ::
  {:ok, snapshot} |
  {:needs_compaction, snapshot}
```

Where `snapshot` is the current summary/tail structure and the return value indicates whether `needs_compaction` should be flipped.

---

## Manual compaction

Fastpaca never rewrites the snapshot for you. When `needs_compaction` is true:

1. Fetch the window via the REST API or SDK.  
2. Decide which `seq` range to replace.  
3. Produce the replacement events (e.g., a summary system message).  
4. Call `POST /v1/conversations/:id/compact`.

Example (trim everything before the last ten turns):

```bash
curl -X POST http://localhost:4000/v1/conversations/chat-45/compact \
  -H "Content-Type: application/json" \
  -d '{
    "from_seq": 1,
    "to_seq": 320,
    "replacement": [
      {
        "role": "system",
        "parts": [
          { "type": "text", "text": "Conversation summary covering seq 1-320..." }
        ]
      }
    ]
  }'
```

You can automate this by:

- Using the TypeScript SDK’s `ctx.autoCompact(async window => ...)` helper.  
- Listening to the websocket stream for `needs_compaction` events and running compaction in a background worker.

---

## Tool calls and reasoning

Fastpaca stores tool calls and reasoning traces as message parts:

```json
{
  "role": "assistant",
  "parts": [
    { "type": "text", "text": "Checking inventory..." },
    { "type": "tool_call", "name": "reserve", "payload": { "sku": 123 } },
    { "type": "reasoning", "tokens": ["plan", "reserve", "confirm"] }
  ]
}
```

Strategies treat these parts like any other content. Use `strip_tool_results` or a custom strategy if you need to drop verbose outputs while keeping the call metadata.

---

## Choosing a policy

| Requirement | Recommendation |
| --- | --- |
| Small assistants (short chats) | `last_n` with `limit: 200`, leave summarisation to ad-hoc jobs. |
| Tool-heavy agents | `strip_tool_results` with a modest `limit` to keep prompts clean. |
| Long-running threads | `budget` and a dedicated summariser invoked via `needs_compaction`. |

Revisit your policy when you change models — larger context windows may let you relax compaction or switch strategies.
