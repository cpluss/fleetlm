---
title: Context Management
sidebar_position: 3
---

# Context Management

Managing your context context is key to scaling an LLM product. Users want full history, but your LLM or agent is operating on a stricter limit where you can only send a certain number of input tokens to it - dictated by its context window. 

It usually works quite well to send all messages to the LLM up until you hit the input token limit (and exceed the context window), but once you reach that you either need to stop processing a context or reduce the data to give your user the illusion of a product that can take all of it into account on each request.

---

## Token budgets & triggers

To determine _when_ it is time to reduce the size of the input (messages) you send to your LLM you usually define

1. A **token budget**, ie. how many tokens you can send as input to the LLM. Popular LLMs have well-defined token budgets, for example claude 4.5 sonnet accepts up to 1M tokens.
2. A **trigger ratio**, which is a percentage of the token budget that you want to compact at. As usually once you hit the complete budget (or limit) you may end up trying to send too much data, which your model provider won't accept and reject the call.

For example, with a budget of `8000` tokens and a trigger at `80%` you would trigger context compaction once the input exceeds `6400` tokens. This gives you breathing room in case the context grows larger when processing the next request without risking hitting a limit (your budget) and entering an unrecoverable state.

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

"Compaction" is the act of reducing the input to your llm while retaining useful data, and throwing away that which you do not need. It is commonly done with strategies such as

* Keep the latest *N* messages, and throw away the rest.
* Strip away detail that the LLM most likely do not need further, e.g. tool calls, reasoning, media too large, etc.
* Maintain a running initial "summary" message at the top, which another LLM continuously builds on by taking new messages and updating it.

There are other creative & more complex ways to manage context such as involving a RAG or Vector DB to save facts about each context for later, but those are not covered by fastpaca since they're quite convoluted and usually aren't needed.

These strategies dictate *what we do when we approach the token budget* within the context context.

## Built-in strategies in fastpaca

| Strategy | What it does | Ideal for |
| --- | --- | --- |
| `last_n` | Keep the latest *N* messages (with token and message limits). | Short chats where recent turns matter most. |
| `skip_parts` | Drop `tool*` & `reasoning` messages, then apply `last_n`. | Agents that generate huge tool outputs or research agents that accrue a lot of reasoning messages. |
| `manual` | Keep everything until the trigger ratio trips, then flip flag `needs_compaction`. | Workflows where you summarise in larger batches. |

You can also use & implement your own strategy by setting the strategy to `manual` and using `needs_compaction` to rewrite the context for the agent by yourself.

## Changing policies

If you fetch a context again but change your policy during the setup it will automatically change the policy on the context going forward. The next time context compaction triggers it will use the new policy rather than the old.

*NOTE: fastpaca does not rebuild the entire context from scratch when you change policies, since that can be an incredibly expensive operation. You can do so manually however by rewriting the context by calling `compact` manually.*

## Choosing a starting policy

| If you want… | Pick… | Notes |
| --- | --- | --- |
| Something simple | `last_n` with `limit: 200` | Great default for short chats. |
| Lean prompts with tools | `skip_parts` | Keeps metadata, removes noisy payloads. Good for most agents. |
| Full control, larger batches | `budget` with `trigger_ratio: 0.7` | Pair with your own summariser. |

Revisit the policy when you change LLMs or expand context length.

---

Next steps: wire this into your backend with the [TypeScript SDK](./typescript-sdk.md) or see full examples in [Examples](./examples.md).
