#!/usr/bin/env node
/**
 * FleetLM Test Client
 *
 * Connects to FleetLM via WebSocket and allows sending/receiving messages
 * in a chat session with an agent.
 */

import { Socket } from "phoenix";

interface Message {
  seq: number;
  sender_id: string;
  kind: string;
  content: any;
  inserted_at: string;
}

interface JoinResponse {
  session_id: string;
  messages: Message[];
}

const WS_URL = process.env.WS_URL || "ws://localhost:4000/socket";
const SESSION_ID = process.env.SESSION_ID || "01JGXAMPLE123456789";
const USER_ID = process.env.USER_ID || process.env.PARTICIPANT_ID || "alice";

console.log("FleetLM Chat Client");
console.log("====================");
console.log(`WebSocket URL: ${WS_URL}`);
console.log(`Session ID: ${SESSION_ID}`);
console.log(`User ID: ${USER_ID}`);
console.log("");

// Connect to Phoenix WebSocket
const socket = new Socket(WS_URL, {
  params: { user_id: USER_ID },
});

socket.connect();

// Join the session channel
const channel = socket.channel(`session:${SESSION_ID}`, {});

channel
  .join()
  .receive("ok", (resp: JoinResponse) => {
    console.log("Joined session:", resp.session_id);
    console.log(`Loaded ${resp.messages.length} previous messages\n`);

    // Display previous messages
    if (resp.messages.length > 0) {
      console.log("Message History:");
      console.log("================");
      resp.messages.forEach((msg) => {
        displayMessage(msg);
      });
      console.log("");
    }

    console.log("Ready to chat! Type your messages below:");
    console.log("(Press Ctrl+C to exit)\n");

    // Setup stdin for sending messages
    setupInteractiveInput();
  })
  .receive("error", (resp: any) => {
    console.error("❌ Failed to join session:", resp);
    process.exit(1);
  });

// Listen for incoming messages
channel.on("message", (payload: Message) => {
  displayMessage(payload);
});

// Listen for backpressure
channel.on("backpressure", (payload: any) => {
  console.log(`Backpressure: ${payload.reason} (retry after ${payload.retry_after_ms}ms)`);
});

function displayMessage(msg: Message) {
  const sender = msg.sender_id === USER_ID ? "You" : msg.sender_id;

  if (msg.kind === "text" && typeof msg.content === "object" && msg.content.text) {
    console.log(`${sender}: ${msg.content.text}`);
  } else if (msg.kind === "text") {
    console.log(`${sender}: ${msg.content}`);
  } else {
    console.log(`${sender} [${msg.kind}]: ${JSON.stringify(msg.content)}`);
  }
}

function setupInteractiveInput() {
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    const text = chunk.toString().trim();

    if (text === "") return;

    // Send message to the channel
    channel
      .push("send", {
        content: {
          kind: "text",
          content: { text: text },
        },
      })
      .receive("error", (err: any) => {
        console.error("❌ Failed to send message:", err);
      });
  });

  process.stdin.on("end", () => {
    console.log("\nDisconnecting...");
    socket.disconnect();
    process.exit(0);
  });
}

// Handle graceful shutdown
process.on("SIGINT", () => {
  console.log("\nDisconnecting...");
  socket.disconnect();
  process.exit(0);
});
