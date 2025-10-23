import process from "node:process";

const apiUrl = process.env.FLEETLM_API_URL ?? "http://localhost:4000";
const agentId = process.env.FLEETLM_AGENT_ID ?? "nextjs-demo-agent";
const agentName = process.env.FLEETLM_AGENT_NAME ?? "Next.js Demo Agent";
const originUrl = process.env.FLEETLM_AGENT_ORIGIN ?? "http://localhost:3000";
const webhookPath = process.env.FLEETLM_AGENT_WEBHOOK_PATH ?? "/api/fleetlm/webhook";
const debounceMs = Number(process.env.FLEETLM_AGENT_DEBOUNCE_MS ?? 250);

const payload = {
  agent: {
    id: agentId,
    name: agentName,
    origin_url: originUrl,
    webhook_path: webhookPath,
    message_history_mode: "tail",
    message_history_limit: 20,
    timeout_ms: 30000,
    debounce_window_ms: debounceMs,
    status: "enabled",
    compaction_enabled: false
  }
};

console.log(`Registering agent '${agentId}' against ${apiUrl}…`);

const response = await fetch(`${apiUrl}/api/agents`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json"
  },
  body: JSON.stringify(payload)
});

if (!response.ok) {
  const detail = await response.text();
  console.error(`Failed to register agent: HTTP ${response.status} ${detail}`);
  process.exit(1);
}

const body = await response.json();
console.log("Agent registered:", body);
