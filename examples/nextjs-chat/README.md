# Fastpaca × Next.js Chat Example

Minimal chat app demonstrating Fastpaca context management with ai-sdk and Next.js.

## Features

- **Pure ai-sdk frontend** - Uses `useChat` hook, no Fastpaca client code needed
- **Backend integration** - All Fastpaca calls in the API route
- **gpt-4o-mini** - 400k context window, affordable
- **Auto-compaction** - `last_n` strategy keeps last 400 messages

## Setup

```bash
cd examples/nextjs-chat
cp .env.example .env.local
# Edit .env.local and add your OPENAI_API_KEY

npm install
npm run dev
```

## How it Works

### Frontend (Standard ai-sdk)
```tsx
// app/page.tsx
import { useChat } from '@ai-sdk/react';

const { messages, input, handleSubmit } = useChat();
// That's it! No Fastpaca code in frontend
```

### Backend (Fastpaca Integration)
```typescript
// app/api/chat/route.ts
export async function POST(req: Request) {
  const { messages } = await req.json();

  // 1. Get context ID from session/user
  const contextId = getContextId(req);

  // 2. Append last message to Fastpaca
  await appendToFastpaca(contextId, messages[messages.length - 1]);

  // 3. Get token-budgeted window from Fastpaca
  const { messages: contextMessages } = await getFastpacaWindow(contextId);

  // 4. Stream to OpenAI
  const result = streamText({
    model: openai('gpt-4o-mini'),
    messages: convertToModelMessages(contextMessages),
  });

  // 5. Auto-append assistant response after stream
  await appendAssistantResponse(contextId, result);

  return result.toUIMessageStreamResponse();
}
```

### Compaction
When `used_tokens > 280k` (70% of 400k), Fastpaca automatically:
1. Drops oldest messages (keeps last 400)
2. Updates snapshot on write path
3. Next `GET /context` returns compacted window

## Architecture

```
Browser → useChat (ai-sdk)
            ↓
      POST /api/chat (Next.js)
            ↓
      Fastpaca REST API
       - Append message
       - Get window (pre-computed!)
       - Auto-compact (on write)
            ↓
      OpenAI gpt-4o-mini
            ↓
      Stream → Browser
```

All Fastpaca logic is hidden in the backend. Frontend is pure ai-sdk.

## Files

- `app/page.tsx` - Chat UI (standard `useChat`)
- `app/api/chat/route.ts` - Fastpaca integration + streaming

## Running

1. Start Fastpaca: `mix phx.server` (from repo root)
2. Start Next.js: `npm run dev`
3. Open: http://localhost:3000
