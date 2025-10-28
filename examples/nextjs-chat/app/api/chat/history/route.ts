import { createClient } from 'fastpaca';

const FASTPACA_URL = process.env.FASTPACA_URL || 'http://localhost:4000/v1';

// Create Fastpaca client
const fastpaca = createClient({ baseUrl: FASTPACA_URL });

export async function POST(req: Request) {
  try {
    const { contextId } = await req.json();

    if (!contextId) {
      return Response.json({ error: 'contextId is required' }, { status: 400 });
    }

    // Get the context
    const ctx = await fastpaca.context(contextId);

    // Fetch message history
    const { messages } = await ctx.getTail({ limit: 100 });

    return Response.json({ messages });
  } catch (error: any) {
    // If context doesn't exist yet, return empty array
    if (error.message?.includes('404') || error.message?.includes('not found')) {
      return Response.json({ messages: [] });
    }

    console.error('Failed to fetch history:', error);
    return Response.json({ error: 'Failed to fetch history' }, { status: 500 });
  }
}
