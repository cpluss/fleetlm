# fastpaca

**Context infra for LLM apps.** Fastpaca keeps full history and maintains your LLM context window in one backend service. 
- **Users need to see every message.**
- **LLMs can only see a limited context window.**

Fastpaca bridges that gap with an append-only history, context compaction, and streaming — all inside one backend service. You stay focused on prompts, tools, UI, and business logic. 

- [Docs](https://docs.fastpaca.com) 
- [Quick Start](https://docs.fastpaca.com/usage/quickstart)

## Installation

```bash
npm install @fastpaca/fastpaca
```

## Usage

```typescript
import { createClient } from '@fastpaca/fastpaca';
import { streamText, convertToModelMessages } from 'ai';
import { openai } from '@ai-sdk/openai';

// Create client
const fastpaca = createClient({ baseUrl: 'http://localhost:4000/v1' });

// Create or get context (idempotent when options provided)
const ctx = await fastpaca.context('chat-123', {
  budget: 400_000,      // e.g., gpt-4o-mini context window
  trigger: 0.7,
  policy: { strategy: 'last_n', config: { limit: 400 } }
});

// Append message (server computes token_count by default)
await ctx.append({
  role: 'user',
  parts: [{ type: 'text', text: 'Hello!' }]
});

// Or pass a known token count for accuracy
await ctx.append({
  role: 'assistant',
  parts: [{ type: 'text', text: 'Hi there!' }]
}, { tokenCount: 12 });

// Get context messages and stream a response
const { messages } = await ctx.context();
const result = streamText({ model: openai('gpt-4o-mini'), messages: convertToModelMessages(messages) });

return result.toUIMessageStreamResponse({
  onFinish: async ({ responseMessage }) => {
    // Optionally pass a known completion token count if your provider returns it
    await ctx.append(responseMessage);
  },
});
```

## API

See [the docs](https://docs.fastpaca.com/) for full API reference.
