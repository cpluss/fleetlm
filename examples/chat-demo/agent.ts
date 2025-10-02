#!/usr/bin/env node
/**
 * FleetLM Test Agent
 *
 * A simple mock agent that receives webhooks from FleetLM and responds
 * with JSONL-formatted messages.
 */

import express from "express";

interface Message {
  seq: number;
  sender_id: string;
  kind: string;
  content: any;
  inserted_at: string;
}

interface WebhookPayload {
  session_id: string;
  agent_id: string;
  user_id: string;
  messages: Message[];
}

const PORT = process.env.PORT || 3000;
const app = express();

app.use(express.json());

// Health check endpoint
app.get("/health", (req, res) => {
  res.json({ status: "ok", agent: "demo-agent" });
});

// Webhook endpoint that FleetLM calls
app.post("/webhook", async (req, res) => {
  const payload = req.body as WebhookPayload;

  console.log("Webhook received:");
  console.log(` Session: ${payload.session_id}`);
  console.log(` Agent: ${payload.agent_id}`);
  console.log(` User: ${payload.user_id}`);
  console.log(` Messages: ${payload.messages.length}`);
  console.log("");

  // Display the conversation
  console.log("Conversation:");
  payload.messages.forEach((msg) => {
    const emoji = msg.sender_id === payload.user_id ? "👤" : "🤖";
    const content = typeof msg.content === "object" && msg.content.text ? msg.content.text : JSON.stringify(msg.content);
    console.log(`  ${emoji} ${msg.sender_id}: ${content}`);
  });
  console.log("");

  // Get the last user message
  const lastMessage = payload.messages[payload.messages.length - 1];

  // Generate responses based on the user's message
  const responses = generateResponses(lastMessage, payload);

  // Set headers for JSONL streaming
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Transfer-Encoding", "chunked");

  // Stream responses as JSONL (newline-delimited JSON) with realistic delays
  console.log(" Sending responses:");

  // Send responses asynchronously with delays to showcase streaming
  let index = 0;
  for (const response of responses) {
    // Add realistic delay between messages (500ms - 1000ms)
    if (index > 0) {
      const delay = Math.floor(Math.random() * 500) + 500; // 500-1000ms
      await new Promise(resolve => setTimeout(resolve, delay));
    }

    console.log(`  ${index + 1}. [${response.kind}] ${JSON.stringify(response.content)}`);
    res.write(JSON.stringify(response) + "\n");
    index++;
  }

  console.log("");
  res.end();
});

function generateResponses(lastMessage: Message, payload: WebhookPayload) {
  // Extract text from content object
  const contentText = typeof lastMessage.content === "object" && lastMessage.content.text
    ? lastMessage.content.text
    : JSON.stringify(lastMessage.content);
  const userMessage = contentText.toLowerCase();
  const responses = [];

  // Simple response logic
  if (userMessage.includes("hello") || userMessage.includes("hi")) {
    responses.push({
      kind: "text",
      content: { text: "Hello! I'm a demo agent. How can I help you today?" },
    });
  } else if (userMessage.includes("help")) {
    responses.push({
      kind: "text",
      content: { text: "I'm a simple demo agent. Try asking me about:" },
    });
    responses.push({
      kind: "text",
      content: { text: "- The weather\n- A joke\n- Math problems\n- Or just chat with me!" },
    });
  } else if (userMessage.includes("weather")) {
    responses.push({
      kind: "text",
      content: { text: "🌤️ The weather is always perfect in the digital realm! It's a sunny 72°F with zero chance of bugs." },
    });
  } else if (userMessage.includes("joke")) {
    responses.push({
      kind: "text",
      content: { text: "Why do programmers prefer dark mode?" },
    });
    // Add a small delay simulation
    responses.push({
      kind: "text",
      content: { text: "Because light attracts bugs! 🐛😄" },
    });
  } else if (userMessage.match(/\d+\s*[\+\-\*\/]\s*\d+/)) {
    // Simple math evaluation
    try {
      const result = eval(userMessage.replace(/[^0-9+\-*/().]/g, ""));
      responses.push({
        kind: "text",
        content: { text: `The answer is: ${result}` },
      });
    } catch (e) {
      responses.push({
        kind: "text",
        content: { text: "Hmm, I couldn't calculate that. Try something like '2 + 2'." },
      });
    }
  } else if (userMessage.includes("bye") || userMessage.includes("goodbye")) {
    responses.push({
      kind: "text",
      content: { text: "Goodbye! It was nice chatting with you! 👋" },
    });
  } else {
    // Echo back with some personality
    const msgCount = payload.messages.length;
    responses.push({
      kind: "text",
      content: { text: `You said: "${contentText}". I'm a simple demo agent, so I'll just acknowledge that!` },
    });
    responses.push({
      kind: "text",
      content: { text: `By the way, we've exchanged ${msgCount} messages so far in this conversation.` },
    });
  }

  return responses;
}

app.listen(PORT, () => {
  console.log("FleetLM Demo Agent");
  console.log("==================");
  console.log(`Agent listening on http://localhost:${PORT}`);
  console.log(`Webhook endpoint: http://localhost:${PORT}/webhook`);
  console.log("");
  console.log("Waiting for webhooks from FleetLM...\n");
});
