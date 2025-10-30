---
title: Context Management
sidebar_position: 3
---

# Context Management

Managing your context is key to scaling an LLM product. Users want full history, but your LLM or agent can only accept a limited number of input tokens, governed by the provider's context length.

Sending all messages to the LLM works until you hit the provider’s input limit. Once you reach it, you either stop processing or reduce the input so users can keep interacting as if everything is considered on each request.

---

## Token budgets & triggers

To determine when to reduce the size of the input (messages) you send to your LLM, define:

1. A **token budget**, i.e., how many tokens you allow as input to the LLM (input only). Popular LLMs publish context lengths; for example, Claude 4.5 Sonnet accepts up to 1M tokens.
2. A **trigger ratio**, which is a percentage of the token budget at which you want to compact. If you hit the full provider limit, you may send too much data and your provider will reject the call.

For example, with a budget of `8000` tokens and a trigger at `80%` you would trigger context compaction once the input exceeds `6400` tokens. This gives you breathing room in case the context grows larger during the next request without risking hitting the provider limit and entering an unrecoverable state.

## Token budgets at a glance

- Configure once when you create the context: `token_budget: 1_000_000`
- Every call to `ctx.context()` (or `GET /v1/contexts/:id/context`) respects that ceiling
- When the snapshot + tail cross the trigger ratio (default `0.7`), `needs_compaction` flips to `true`
- Override the trigger ratio per context if you want earlier/later warnings

```bash
curl -X PUT http://localhost:4000/v1/contexts/docs-demo \
  -H "Content-Type: application/json" \
  -d '{
    "token_budget": 1000000,
    "trigger_ratio": 0.65,
    "policy": {
      "strategy": "last_n",
      "config": { "limit": 400 }
    }
  }'
```

## Context compaction strategy

"Compaction" is the act of reducing the input to your LLM while retaining useful data and dropping what you don't need. Common strategies:

* Keep the latest *N* messages and throw away the rest.
* Strip away detail the LLM likely does not need, e.g., tool calls, reasoning, media too large, etc.
* Maintain a running initial "summary" at the top, which another LLM updates by incorporating new messages.

There are other ways to manage context, such as using RAG or a vector DB to save facts per context, but those are not covered by Fastpaca.

These strategies dictate what to do as you approach the token budget within the context.

## Built-in strategies in fastpaca

| Strategy | What it does | Ideal for |
| --- | --- | --- |
| `last_n` | Keep the latest *N* messages (with token and message limits). | Short chats where recent turns matter most. |
| `skip_parts` | Drop `tool*` & `reasoning` messages, then apply `last_n`. | Agents that generate huge tool outputs or research agents that accrue a lot of reasoning messages. |
| `manual` | Keep everything until the trigger ratio trips, then flip flag `needs_compaction`. | Workflows where you summarise in larger batches. |

You can also implement your own strategy by setting the strategy to `manual` and using `needs_compaction` to decide when to rewrite the context yourself.

## Changing policies

If you fetch a context again and change your policy during setup, the context adopts the new policy going forward. The next time compaction triggers, it uses the new policy.

*NOTE: Fastpaca does not rebuild the entire context when you change policies because that can be expensive. You can do so manually by rewriting the context via `compact`.*

## Choosing a starting policy

| If you want… | Pick… | Notes |
| --- | --- | --- |
| Something simple | `last_n` with `limit: 200` | Great default for short chats. |
| Lean prompts with tools | `skip_parts` | Keeps metadata, removes noisy payloads. Good for most agents. |
| Full control, larger batches | `manual` with `trigger_ratio: 0.7` | Pair with your own summariser. |

Revisit the policy when you change LLMs or expand context length.

---

Next steps: wire this into your backend with the [TypeScript SDK](./typescript-sdk.md) or see full examples in [Examples](./examples.md).
