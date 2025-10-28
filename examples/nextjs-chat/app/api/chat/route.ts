import { openai } from '@ai-sdk/openai';
import { streamText, convertToModelMessages, UIMessage } from 'ai';
import { createClient } from '@fastpaca/fastpaca';

export const maxDuration = 30;

const FASTPACA_URL = process.env.FASTPACA_URL || 'http://localhost:4000/v1';

// Create Fastpaca client
const fastpaca = createClient({ baseUrl: FASTPACA_URL });

export async function POST(req: Request) {
  const { messages, contextId } = await req.json();

  if (!contextId) {
    return Response.json({ error: 'contextId is required' }, { status: 400 });
  }

  // 1. Get or create context (idempotent PUT if config provided)
  const ctx = await fastpaca.context(contextId, {
    budget: 128_000,  // gpt-4o-mini context window
    trigger: 0.7,
    policy: {
      strategy: 'last_n',
      config: { limit: 400 },
    },
  });

  // 2. Append user message (last message in array)
  const lastMessage = messages[messages.length - 1];
  if (lastMessage) {
    await ctx.append(lastMessage);
  }

  // 3. Get context messages from fastpaca
  const { messages: contextMessages } = await ctx.context();

  // 4. Stream response
  return streamText({
    model: openai('gpt-4o-mini'),
    messages: convertToModelMessages(contextMessages),
  }).toUIMessageStreamResponse({
    onFinish: async ({ responseMessage }) => {
      // FastpacaMessage accepts any object with role and parts
      await ctx.append(responseMessage);
    },
  });
}
