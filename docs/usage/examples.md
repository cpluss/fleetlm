---
title: Examples
sidebar_position: 5
---

# Examples

End-to-end snippets that show how Fastpaca fits into common workflows.

---

## Streaming chat route (Next.js + ai-sdk)

```typescript title="app/api/chat/route.ts"
import { createClient } from '@fastpaca/fastpaca';
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

export async function POST(req: Request) {
  const { contextId, message } = await req.json();

  const fastpaca = createClient({ baseUrl: process.env.FASTPACA_URL || 'http://localhost:4000/v1' });
  const ctx = await fastpaca.context(contextId, { budget: 1_000_000 });

  await ctx.append({
    role: 'user',
    parts: [{ type: 'text', text: message }]
  });

  const { messages } = await ctx.context();
  return streamText({
    model: openai('gpt-4o-mini'),
    messages,
  }).toUIMessageStreamResponse({
    onFinish: async ({ responseMessage }) => {
      await ctx.append(responseMessage);
    },
  });
}
```

---

## Non-streaming response (Anthropic)

```typescript
import { createClient } from '@fastpaca/fastpaca';
import { generateText } from 'ai';
import { anthropic } from '@ai-sdk/anthropic';

const fastpaca = createClient({ baseUrl: process.env.FASTPACA_URL || 'http://localhost:4000/v1' });
const ctx = await fastpaca.context('chat_non_stream', { budget: 1_000_000 });

await ctx.append({
  role: 'user',
  parts: [{ type: 'text', text: 'Summarise the release notes.' }]
});

const context = await ctx.context();

const { text } = await generateText({
  model: anthropic('claude-3-opus'),
  messages: context.messages
});

await ctx.append({
  role: 'assistant',
  parts: [{ type: 'text', text }]
});
```

---

## Manual compaction with LLM-generated summary

```typescript
const { needs_compaction, messages } = await ctx.context();

if (needs_compaction) {
  const { summary, remainingMessages } = await summarise(messages);
  await ctx.compact([
    { role: 'system', parts: [{ type: 'text', text: summary }] },
    ...remainingMessages
  ]);
}
```

---

## Switching providers mid-context

```typescript
const fastpaca = createClient({ baseUrl: process.env.FASTPACA_URL || 'http://localhost:4000/v1' });
const ctx = await fastpaca.context('mixed-sources', { budget: 1_000_000 });

await ctx.append({
  role: 'user',
  parts: [{ type: 'text', text: 'Explain vector clocks.' }]
});

await ctx.append({
  role: 'assistant',
  parts: [{
    type: 'text',
    text: await streamText({
      model: openai('gpt-4o'),
      messages: await ctx.context().then(c => c.messages)
    }).text()
  }]
});

await ctx.append({
  role: 'user',
  parts: [{ type: 'text', text: 'Now explain like I’m five.' }]
});

await ctx.append({
  role: 'assistant',
  parts: [{
    type: 'text',
    text: await streamText({
      model: anthropic('claude-3-haiku'),
      messages: await ctx.context().then(c => c.messages)
    }).text()
  }]
});
```

---

## Raw REST calls with curl

```bash
# Append tool call output
curl -X POST http://localhost:4000/v1/contexts/support/messages \
  -H "Content-Type: application/json" \
  -d '{
    "message": {
      "role": "assistant",
      "parts": [
        { "type": "text", "text": "Fetching the latest logs..." },
        { "type": "tool_call", "name": "fetch-logs", "payload": {"tail": 200} }
      ]
    }
  }'
```

```bash
# Get the last 50 messages
curl "http://localhost:4000/v1/contexts/support/tail?limit=50"
```

---

These examples mirror the SDK helpers, the REST API, and the websocket stream described elsewhere in the docs. Mix and match based on how your application is structured.
