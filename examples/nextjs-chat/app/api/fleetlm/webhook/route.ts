import { NextRequest } from "next/server";

export const runtime = "nodejs";

type IncomingMessage = {
  seq: number;
  sender_id: string;
  kind: string;
  content: any;
};

type WebhookPayload = {
  session_id: string;
  agent_id: string;
  user_id: string;
  messages: IncomingMessage[];
};

const encoder = new TextEncoder();

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const encodeLine = (value: Record<string, unknown>) =>
  encoder.encode(`${JSON.stringify(value)}\n`);

const replyTemplate = (userText: string, payload: WebhookPayload) => {
  const lastMessages = payload.messages.slice(-3).map((message) => {
    const sender = message.sender_id === payload.user_id ? "user" : "agent";
    return `- ${sender} (#${message.seq}): ${summariseContent(message.content)}`;
  });

  return [
    `You said: ${userText || "…"}.`,
    "",
    "This answer is streamed from a Next.js API route.",
    "Things to try next:",
    "• Edit `app/api/fleetlm/webhook/route.ts` to call your own model or tool.",
    "• Inspect the streaming chunks in the browser console.",
    "• Update `register-agent.mjs` to tweak debounce or history limits.",
    "",
    "Recent context:",
    ...lastMessages
  ].join("\n");
};

const summariseContent = (content: any) => {
  if (!content) return "(no content)";
  if (typeof content.text === "string") return content.text;

  if (typeof content === "object" && typeof content.content?.text === "string") {
    return content.content.text;
  }

  return JSON.stringify(content);
};

export async function POST(request: NextRequest) {
  let payload: WebhookPayload;

  try {
    payload = (await request.json()) as WebhookPayload;
  } catch (error) {
    console.error("Invalid webhook payload", error);
    return new Response(JSON.stringify({ error: "invalid payload" }), { status: 400 });
  }

  const lastMessage = payload.messages.at(-1);
  const userText = lastMessage ? summariseContent(lastMessage.content) : "";
  const reply = replyTemplate(userText, payload);
  const messageId = `nextjs-${Date.now()}`;
  const partId = `${messageId}-text`;
  const startedAt = Date.now();

  const stream = new ReadableStream({
    async start(controller) {
      controller.enqueue(
        encodeLine({
          type: "start",
          messageId,
          messageMetadata: { mode: "nextjs-demo" }
        })
      );

      controller.enqueue(
        encodeLine({
          type: "text-start",
          id: partId
        })
      );

      for (const char of reply) {
        controller.enqueue(
          encodeLine({
            type: "text-delta",
            id: partId,
            delta: char
          })
        );
        await delay(35);
      }

      controller.enqueue(
        encodeLine({
          type: "text-end",
          id: partId
        })
      );

      controller.enqueue(
        encodeLine({
          type: "finish",
          message: {
            id: messageId,
            role: "assistant",
            parts: [
              {
                type: "text",
                text: reply,
                state: "done"
              }
            ]
          },
          messageMetadata: {
            latency_ms: Date.now() - startedAt,
            source: "nextjs-demo"
          }
        })
      );

      controller.close();
    }
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "application/json",
      "Transfer-Encoding": "chunked",
      "Cache-Control": "no-store"
    }
  });
}
