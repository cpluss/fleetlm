---
title: Next.js Example
sidebar_position: 2
---

# Next.js Example

Spin up a full-stack sandbox that connects FleetLM to a Next.js app. The example pairs three pieces:

- **Browser UI** - React client joins the FleetLM session channel, renders live `stream_chunk` events, and keeps history consistent with `seq` cursors.
- **Webhook** - Next.js API route that receives FleetLM payloads and streams [AI SDK UI chunks](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol). Replace the demo response with your own LLM call.
- **Utilities** - API routes that proxy FleetLM’s REST endpoints plus a helper script to register the agent.

## 1. Prepare the Environment

```bash
cd examples/nextjs-chat
cp .env.example .env.local

# If FleetLM runs inside Docker, point the webhook origin at host.docker.internal
# FLEETLM_AGENT_ORIGIN=http://host.docker.internal:3000
```

Ensure FleetLM is running locally (`mix phx.server` or `docker compose up`) and Postgres is accessible.

## 2. Install and Register

```bash
npm install
npm run register-agent
```

The registration script uses `.env.local` to create an agent called `nextjs-demo-agent` with:

- Debounced webhook dispatch (`FLEETLM_AGENT_DEBOUNCE_MS`)
- Tail history window (20 messages)
- Compaction disabled (tweak in `scripts/register-agent.mjs` if you want to demo it)

## 3. Launch the App

```bash
npm run dev
```

Visit http://localhost:3000. Chat messages flow as follows:

1. Browser posts to `/api/fleetlm/session` (creates a session via FleetLM REST) and connects to `ws://localhost:4000/socket`.
2. When you send a message, `/api/fleetlm/send` proxies the POST to FleetLM.
3. FleetLM stores the message, invokes the Next.js webhook, and streams JSONL chunks back over Phoenix channels.
4. The UI renders live tokens before persisting the final assistant message when the webhook emits `finish`.

## Key Files

| Path | What it shows |
| --- | --- |
| `components/chat-app.tsx` | Phoenix channel client, message rendering, streaming UX. |
| `app/api/fleetlm/webhook/route.ts` | Streaming webhook with AI SDK chunks - swap in your own LLM/tool invocation here. |
| `app/api/fleetlm/session/route.ts` | How to create/list sessions from a Next.js backend. |
| `scripts/register-agent.mjs` | Register an agent with debounce + history limits. |

## Call a Real LLM

Drop your model call into `app/api/fleetlm/webhook/route.ts`:

```ts
const response = await openai.responses.stream({
  model: "gpt-4.1",
  input: [{ role: "user", content: userText }]
});

controller.enqueue(encodeLine({ type: "text-start", id: partId }));

for await (const delta of response) {
  controller.enqueue(encodeLine({ type: "text-delta", id: partId, delta }));
}

controller.enqueue(encodeLine({ type: "text-end", id: partId }));
controller.enqueue(encodeLine({ type: "finish", message: finalMessage }));
```

FleetLM handles retries, ordering, and persistence regardless of which provider you call.

## Next Steps

- Enable compaction in `register-agent.mjs` and implement a summary route to see the FSM transition into `:compacting`.
- Point `FLEETLM_AGENT_ORIGIN` at a VPC ingress or tunnel to simulate regulated deployments.
- Port the webhook to your preferred stack (FastAPI, Rails, Go) - the UI keeps working as long as FleetLM receives AI SDK chunks.
