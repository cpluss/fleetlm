# Concepts

FleetLM sits between your users, your UI, and your agent logic. This guide covers the mental model you need before touching APIs or digging into implementation details.

## Actors

- **User** - the human participant identified by `user_id`. A user owns a single inbox stream and can join many sessions.
- **Agent** - a webhook you register with FleetLM. The agent runs your LLM/tooling logic and responds on behalf of the assistant.
- **Client** - browsers, CLIs, or services that call FleetLM APIs to send messages and render the conversation.
- **Session** - a one-to-one conversation between a user and an agent, identified by `session_id`.
- **Inbox** - an aggregated stream per user that surfaces activity across all of their sessions.

## Building Blocks

- **Session** - a conversation between one human and one agent. Identified by `session_id`, replayable from sequence `seq = 0` onward.
- **Agent** - your webhook implementation. FleetLM calls it with the latest conversation snapshot and expects a streamed response.
- **Client** - anything consuming the experience (browser, CLI, mobile app). Clients send user messages and render agent responses.
- **Inbox** - an aggregate stream per user so multiple sessions stay discoverable.

Everything else-Raft, workers, compaction-exists so these building blocks behave predictably at scale.

## Runtime Flow (Conceptual)

1. **A message arrives**: clients post over REST or push on the WebSocket. FleetLM assigns the next `seq` number and immediately broadcasts the user message to any subscribers.
2. **The agent is asked to catch up**: FleetLM guarantees the agent sees every user message in order. Your webhook receives the current transcript slice and starts streaming chunks back (AI SDK JSONL).
3. **Streaming vs persistence**: while the webhook streams, FleetLM fans the chunks out to every connected client. Once a terminal chunk (`finish` or `abort`) shows up, FleetLM persists a single assistant message capturing the final state.
4. **Clients reconcile**: reconnections or late joiners request messages after their last seen sequence. FleetLM replays the persisted log so UIs rebuild state deterministically.

> **At-least-once delivery** - always treat `seq` as source of truth. Streaming chunks are ephemeral helpers for rich UX, not a permanent record.

## Responsibilities

| Layer | Owns | Think about |
| --- | --- | --- |
| FleetLM | Ordering, durability, fanout, retry semantics, context budgeting triggers | Cluster sizing, webhook timeouts, telemetry hooks |
| Your webhook | Business logic, LLM/tool calls, summarisation strategy, metadata | Prompt design, API keys, batching/debouncing trade-offs |
| Your client | Auth, UX, session switching, rendering live chunks, storing `last_seq` | Offline behaviour, optimistic UI, reconnect logic |

Understanding this split keeps integrations focused: FleetLM is infrastructure; you supply intelligence and presentation.

## Context Management (Big Picture)

Large conversations eventually exceed LLM limits. Rather than pushing that decision into every client, FleetLM:

- Tracks how much context an agent has consumed.
- Triggers a **compaction** pass when budgets are exceeded.
- Calls your summariser webhook so you decide what stays in the trimmed transcript.

Think of compaction as “reset the shared memory so the agent remains coherent.” You set the budgets and supply the summariser; FleetLM schedules the work and makes sure nothing is lost. Dive deeper in [Agent Webhooks](../integrations/agents.md#compaction) and [Architecture](./architecture.md#compaction).

## Reliability Promises

- **Ordered log** - every message gets a strictly increasing `seq`. Replays are deterministic.
- **Durable persistence** - a message is acknowledged only after quorum replication. Crashes or restarts do not drop messages.
- **Realtime streaming** - live chunks ride PubSub, but the log remains canonical. Clients must merge both views.
- **Leader failover** - the cluster elects new leaders automatically; clients simply reconnect.

These guarantees let you build product features (drafts, audits, analytics) without worrying about infrastructure edge cases.

## Observability Mindset

FleetLM emits telemetry for:

- Webhook lifecycle (dispatch start/stop, retries, latency)
- Streaming throughput (`stream_chunk`)
- Compaction decisions (triggered, completed, failures)

Hook these into your monitoring stack so you know when agents slow down or summaries thrash. Understanding the signal surface makes production operations calm.

## Where to Go Next

- Wire up your webhook with the [Agent Webhooks guide](../integrations/agents.md).
- Learn how clients consume the log and live stream in [Clients](../integrations/client.md).
- Run the [Next.js example](../getting-started/nextjs-example.md) to see everything working together.
