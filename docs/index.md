---
title: FleetLM
slug: /
sidebar_position: 0
---

# FleetLM

**Context infra for LLM apps.** FleetLM collapses the datastore + pub/sub + stream orchestration stack into one layer so you can build conversational products without stitching infrastructure together.

- **[Quick Start](./getting-started/quickstart.md)** - spin up FleetLM locally.
- **[Example Next.js App](./getting-started/nextjs-example.md)** - see streaming + compaction end to end.
- **[Architecture](./core/architecture.md)** & **[Benchmarks](./operations/benchmarks.md)** - understand internals and performance.

## The Context Trap

1. Simple LLM calls → works great  
2. Add persistence → need database  
3. Multi-device sync → need pub/sub  
4. Context limits hit → need compaction  
5. Debug sessions → need event log  
6. **Five systems. Distributed nightmare.**

FleetLM does all of this out of the box. Write stateless webhooks. Deploy with Docker Compose (or Kubernetes). FleetLM handles state, ordering, replay, and compaction.

![](./img/high-level-clustered.png)

FleetLM calls your webhooks when messages arrive. You own the LLM logic. FleetLM guarantees durability, fan-out, and context management.

## How FleetLM Works

1. **Send from your frontend** - join the session channel and push messages with the TypeScript client or REST.  
   ```ts
   import { FleetLMClient } from "@fleetlm/client";

   const client = new FleetLMClient({ userId: "alice", agentId: "support-bot" });
   client.on("message", (msg) => console.log(msg));
   client.sendMessage("Hello!");
   ```
2. **FleetLM calls your webhook** - the runtime persists the message, then POSTs the latest transcript to your API route. Stream the agent response back using AI SDK chunks.  
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
3. **Compaction keeps context bounded** - configure a token budget per agent. When usage crosses the threshold, FleetLM invokes your compaction webhook so you can summarise or extract key facts.  
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
   Summaries replace old transcripts in the sliding window while the full history stays replayable for audits.

## What FleetLM Handles vs Your App

| FleetLM | You |
| --- | --- |
| Sequenced, durable log backed by Raft + Postgres | Decide when to send user input and how to render responses |
| Webhook orchestration, retries, chunk assembly, compaction triggers | Implement webhook logic (LLM calls, tools, summaries) |
| PubSub fan-out + replay from `last_seq` | Build UIs (web, mobile, CLI) and manage user auth |
| Telemetry hooks for dispatch latency, chunk volume, compaction events | Set alerts, monitor agent health, tune budgets |

Need the high-level system design? Jump to [Architecture](./core/architecture.md). Want to plug in your webhook right away? Start with [Agent Webhooks](./integrations/agents.md).

## Why Teams Pick FleetLM

- **Framework freedom** - agents are plain webhooks (Next.js, FastAPI, Phoenix, Go).  
- **Durable ordering** - Raft consensus, at-least-once delivery, zero silent drops.  
- **Realtime delivery** - WebSockets stream every chunk; REST and inbox endpoints cover polling needs.  
- **Automatic failover** - leader election recovers from node loss in ~150ms.  
- **Scales horizontally** - add nodes to handle more concurrent sessions; 256 Raft groups shard traffic.  
- **Easy to evaluate** - Docker Compose for local play and release images for Kubernetes.

## Self-Host

FleetLM ships under Apache 2.0 and is production-ready to run in your own infrastructure. Bring Postgres, deploy to your preferred environment (Kubernetes, ECS, bare metal), and keep full control. See [Deployment](./operations/deployment.md) for patterns and checklists.

## Where to Go Next

- Follow the [Quick Start](./getting-started/quickstart.md) to spin up FleetLM locally.  
- Fork the [Next.js example](./getting-started/nextjs-example.md) and see streaming + compaction end to end.  
- Dive into [Concepts](./core/concepts.md) for the mental model, then explore [Clients](./integrations/client.md) and [Agent Webhooks](./integrations/agents.md).

**[GitHub Repository](https://github.com/cpluss/fleetlm)**
