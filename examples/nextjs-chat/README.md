# FleetLM × Next.js Demo

A full-stack example that pairs FleetLM with a Next.js app:

- **Browser UI** - React client joins the FleetLM session channel, renders streaming chunks, and persists history.
- **Webhook** - Next.js API route responds to FleetLM with AI SDK JSONL chunks (edit this file to call your own LLM or tools).
- **Utilities** - API routes proxy session/message calls plus a script to register the agent against FleetLM.

## Prerequisites

- Node.js 18+
- FleetLM running locally (`mix phx.server` or `docker compose up`)
- Env vars from `.env.example`

> ℹ️ If FleetLM runs inside Docker on macOS/Windows, set `FLEETLM_AGENT_ORIGIN=http://host.docker.internal:3000` so the container can reach your Next.js webhook.

## Setup

```bash
cd examples/nextjs-chat
cp .env.example .env.local
npm install

# Register the demo agent (id + webhook URL taken from .env.local)
npm run register-agent

# Start the Next.js app
npm run dev
```

Open http://localhost:3000 and send a message. FleetLM persists the user input, invokes the Next.js webhook, and streams each chunk back into the UI in real time.

### What to look at

| File | Purpose |
| --- | --- |
| `app/api/fleetlm/webhook/route.ts` | Streaming webhook - swap the demo text generator for your own LLM call. |
| `components/chat-app.tsx` | Phoenix channel client, message rendering, and live chunk handling. |
| `app/api/fleetlm/session/route.ts` | Thin proxy that creates sessions through FleetLM’s REST API. |
| `scripts/register-agent.mjs` | Registers the Next.js webhook with FleetLM (id, debounce, history window). |

## Calling a Real LLM

The webhook currently streams a handcrafted response. To delegate to a provider:

1. Add an API key to `.env.local` (e.g. `OPENAI_API_KEY=sk-...`).
2. Replace the body of `replyTemplate` in `app/api/fleetlm/webhook/route.ts` with a call to your provider.
3. Forward streamed tokens as AI SDK chunks:

```ts
controller.enqueue(encodeLine({ type: "text-start", id: partId }));
for await (const delta of providerStream) {
  controller.enqueue(encodeLine({ type: "text-delta", id: partId, delta }));
}
controller.enqueue(encodeLine({ type: "text-end", id: partId }));
controller.enqueue(encodeLine({ type: "finish", message: yourFinalMessage }));
```

FleetLM will handle retries, state reconciliation, and message persistence regardless of the backend you call.

## Tweaks

- Change `FLEETLM_AGENT_DEBOUNCE_MS` in `.env.local` to watch how FleetLM batches fast message bursts.
- Enable compaction by setting `compaction_enabled` + `compaction_webhook_url` in `scripts/register-agent.mjs`, then implement a summary path in your Next.js app.
- Use the REST proxies in `app/api/fleetlm` as a template for integrating FleetLM into your own backend.

## Cleanup

To remove the demo agent:

```bash
curl -X DELETE "$FLEETLM_API_URL/api/agents/$FLEETLM_AGENT_ID"
```

This keeps your FleetLM registry tidy when you create production agents.
