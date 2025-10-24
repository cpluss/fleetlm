---
title: Examples
sidebar_position: 5
---

# Examples

End-to-end snippets that show how Fastpaca fits into common workflows.

---

## Streaming chat route (Next.js + ai-sdk)

```typescript title="app/api/chat/route.ts"
import { fastpaca } from 'fastpaca';
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

export async function POST(req: Request) {
  const { conversationId, message } = await req.json();

  const ctx = await fastpaca.context(conversationId).budget(1_000_000);

  await ctx.append({ role: 'user', content: message });

  return ctx.stream((messages) =>
    streamText({ model: openai('gpt-4o-mini'), messages })
  ).toResponse();
}
```

---

## Non-streaming response (Anthropic)

```typescript
import { fastpaca } from 'fastpaca';
import { generateText } from 'ai';
import { anthropic } from '@ai-sdk/anthropic';

const ctx = await fastpaca.context('chat_non_stream').budget(1_000_000);

await ctx.append({ role: 'user', content: 'Summarise the release notes.' });

const window = await ctx.window();

const { text } = await generateText({
  model: anthropic('claude-3-opus'),
  messages: window.messages
});

await ctx.append({ role: 'assistant', content: text });
```

---

## Manual compaction with LLM-generated summary

```typescript
const window = await ctx.window();

if (window.needsCompaction) {
  const head = window.messages.slice(0, -8);

  const { text: summary } = await generateText({
    model: openai('gpt-4o-mini'),
    messages: [
      { role: 'system', content: 'Summarise the following chat in one paragraph.' },
      ...head
    ]
  });

  await ctx.compact({
    fromSeq: head[0].seq,
    toSeq: head[head.length - 1].seq,
    replacement: [
      { role: 'system', parts: [{ type: 'text', text: summary }] }
    ]
  });
}
```

---

## Switching providers mid-conversation

```typescript
const ctx = await fastpaca.context('mixed-sources').budget(1_000_000);

await ctx.append({ role: 'user', content: 'Explain vector clocks.' });

await ctx.append({
  role: 'assistant',
  content: await streamText({
    model: openai('gpt-4o'),
    messages: await ctx.window().then(w => w.messages)
  }).text()
});

await ctx.append({ role: 'user', content: 'Now explain like I’m five.' });

await ctx.append({
  role: 'assistant',
  content: await streamText({
    model: anthropic('claude-3-haiku'),
    messages: await ctx.window().then(w => w.messages)
  }).text()
});
```

---

## Raw REST calls with curl

```bash
# Append tool call output
curl -X POST http://localhost:4000/v1/conversations/support/events \
  -H "Content-Type: application/json" \
  -d '{
    "event": {
      "role": "assistant",
      "parts": [
        { "type": "text", "text": "Fetching the latest logs..." },
        { "type": "tool_call", "name": "fetch-logs", "payload": {"tail": 200} }
      ]
    }
  }'
```

```bash
# Replay the last 50 events
curl "http://localhost:4000/v1/conversations/support/events?from_seq=-50"
```

---

These examples mirror the SDK helpers, the REST API, and the websocket stream described elsewhere in the docs. Mix and match based on how your application is structured.
