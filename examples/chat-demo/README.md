# FleetLM Chat Demo

This example demonstrates how to use FleetLM for agentic chat:

- **Client** - A TypeScript WebSocket client that connects to FleetLM and sends/receives messages
- **Agent** - A simple mock agent that responds to webhooks from FleetLM

## Setup

### 1. Install Dependencies

```bash
cd examples/chat-demo
npm install
```

### 2. Initialize Database

Make sure the FleetLM database is running and migrated:

```bash
cd ../..  # Back to fleetlm root
mix ecto.create
mix ecto.migrate
```

### 3. Start the FleetLM Server

```bash
mix phx.server
```

The server will start on `http://localhost:4000`

## Running the Demo

You need **4 terminal windows** open:

### Terminal 1: FleetLM Server

Should already be running from step 3 above.

### Terminal 2: Register Agent & Create Session

First, register the demo agent:

```bash
curl -X POST http://localhost:4000/api/agents \
  -H "Content-Type: application/json" \
  -d '{
    "id": "demo-agent",
    "name": "Demo Agent",
    "origin_url": "http://localhost:3000",
    "webhook_path": "/webhook",
    "context": {
      "strategy": "last_n",
      "config": {"limit": 10}
    },
    "timeout_ms": 30000,
    "status": "enabled"
  }'
```

Then create a session:

```bash
curl -X POST http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "alice",
    "agent_id": "demo-agent",
    "metadata": {"demo": true}
  }'
```

**Important**: Save the `session_id` from the response! You'll need it for the client.

### Terminal 3: Demo Agent

```bash
cd examples/chat-demo
npm run agent
```

The agent will listen on port 3000 for webhooks from FleetLM.

### Terminal 4: Interactive Chat Client

The client now has an interactive menu to manage sessions:

```bash
cd examples/chat-demo
npm run client
```

Features:
- List existing sessions with timestamps
- Create new sessions
- Real-time chat with streaming responses
- Keyboard navigation (arrows, enter, q to quit)

**Environment Variables** (optional):
```bash
USER_ID=alice \
AGENT_ID=demo-agent \
API_URL=http://localhost:4000 \
WS_URL=ws://localhost:4000/socket \
npm run client
```

## Usage

### Session Selection
```
Select Session
User: alice | Agent: demo-agent

No sessions

> Create New Session

up/down: navigate | enter: select | q: quit
```

### Chat View
```
Session: 01K6GR2EV9Z7PSMEVVJ5M954CH

You: hello
Agent: Hello! I'm a demo agent. How can I help you today?
You: tell me a joke
Agent: Why do programmers prefer dark mode?
Agent: Because light attracts bugs!

Message: _
```

### Agent Capabilities

The demo agent understands:
- **Greetings**: "hello", "hi"
- **Help**: "help"
- **Weather**: "weather"
- **Jokes**: "joke" (responses come with realistic delays to showcase async streaming!)
- **Math**: "2 + 2", "10 * 5", etc.
- **Goodbye**: "bye", "goodbye"

**Note**: The agent adds realistic delays (500ms-1s) between multiple responses to showcase the asynchronous streaming nature of FleetLM!

## Architecture

```
┌─────────┐          WebSocket          ┌─────────────┐
│ Client  │ ◄────────────────────────► │  FleetLM    │
└─────────┘    Phoenix Channel          │  Server     │
                                        └──────┬──────┘
                                               │
                                               │ HTTP Webhook
                                               │ (JSONL response)
                                               ▼
                                        ┌─────────────┐
                                        │   Agent     │
                                        │  (Express)  │
                                        └─────────────┘
```

### Client → FleetLM
- Connects via WebSocket to `/socket/websocket`
- Joins channel `session:01JGXAMPLE123456789`
- Sends messages with `send` event
- Receives messages via `message` events

### FleetLM → Agent
- POSTs to `http://localhost:3000/webhook`
- Payload includes session details and message history
- Agent responds with JSONL (newline-delimited JSON)
- Each line: `{"kind": "text", "content": "message"}`

### Agent → Client
- Agent responses are appended to the session
- FleetLM broadcasts them via WebSocket
- Client displays them in real-time

## Environment Variables

### Client

- `WS_URL` - WebSocket URL (default: `ws://localhost:4000/socket`)
- `SESSION_ID` - Session ID (default: `01JGXAMPLE123456789`)
- `USER_ID` - User identifier (default: `alice`)

### Agent

- `PORT` - Agent port (default: `3000`)

## Customization

### Modify the Agent

Edit `agent.ts` to change how the agent responds. The agent receives the full conversation history and can:

- Access all messages via `payload.messages`
- Return multiple response messages
- Use different message kinds (not just "text")
- Add metadata to messages

### Create Additional Sessions

Use the REST API:

```bash
curl -X POST http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "bob",
    "agent_id": "demo-agent",
    "metadata": {}
  }'
```

Then use the returned session ID with the client:

```bash
SESSION_ID=<new-session-id> USER_ID=bob npm run client
```
