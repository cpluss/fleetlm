import { openai } from '@ai-sdk/openai';
import { streamText } from 'ai';
import { createClient } from 'fastpaca';

export const maxDuration = 30;

const FASTPACA_URL = process.env.FASTPACA_URL || 'http://localhost:4000/v1';
const CONTEXT_ID = 'nextjs-demo-chat';  // Simple demo: one global context

// Create Fastpaca client
const fastpaca = createClient({ baseUrl: FASTPACA_URL });

export async function POST(req: Request) {
  const { messages } = await req.json();

  // 1. Get or create context (idempotent PUT if config provided)
  const ctx = await fastpaca.context(CONTEXT_ID, {
    budget: 400_000,  // gpt-4o-mini context window
    trigger: 0.7,
    policy: {
      strategy: 'last_n',
      config: { limit: 400 },
    },
  });

  // 2. Append user message (last message in array)
  const lastMessage = messages[messages.length - 1];
  if (lastMessage) {
    await ctx.append({
      role: lastMessage.role,
      parts: lastMessage.parts,
    });
  }

  // 3. Stream to OpenAI via Fastpaca helper
  return ctx.stream(async (contextMessages) => {
    const aiMessages = contextMessages.map((msg) => ({
      role: msg.role as 'user' | 'assistant' | 'system',
      content: msg.parts
        .filter((p) => p.type === 'text')
        .map((p) => (p as any).text)
        .join(' '),
    }));

    return streamText({
      model: openai('gpt-4o-mini'),
      messages: aiMessages as any,
      // Explicitly append on finish
      onFinish: async ({ text }) => {
        await ctx.append({
          role: 'assistant',
          parts: [{ type: 'text', text }],
        });
      },
    });
  });
}
