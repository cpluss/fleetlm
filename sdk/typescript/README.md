# fastpaca

TypeScript client for Fastpaca - context infrastructure for LLM apps.

## Installation

```bash
npm install fastpaca
```

## Usage

```typescript
import { createClient } from 'fastpaca';
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

// Create client
const fastpaca = createClient({
  baseUrl: 'http://localhost:4000/v1'
});

// Create or get context (idempotent when options provided)
const ctx = await fastpaca.context('chat-123', {
  budget: 400_000,      // gpt-4o-mini context window
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

// Get context window
const { messages } = await ctx.context();

// Stream response (ai-sdk)
return ctx.stream(messages =>
  streamText({ model: openai('gpt-4o-mini'), messages })
);
```

## API

See `docs/` for full API reference.
