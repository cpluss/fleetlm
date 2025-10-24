/**
 * FleetLM k6 Benchmark Library
 *
 * Shared utilities and configuration for k6 benchmarks.
 */

import http from 'k6/http';
import { check } from 'k6';

// ============================================================================
// Configuration
// ============================================================================

export const config = {
  apiUrl: __ENV.API_URL || 'http://localhost:4000/api',
  wsUrl: __ENV.WS_URL || 'ws://localhost:4000/socket/websocket',
  agentId: __ENV.AGENT_ID || 'bench-echo-agent',
  agentUrl: __ENV.AGENT_URL || 'http://localhost:4001',
  runId: __ENV.RUN_ID || `${Date.now()}-${Math.floor(Math.random() * 10000)}`,
};

export const jsonHeaders = {
  headers: {
    'Content-Type': 'application/json',
  },
};

// ============================================================================
// Agent Setup
// ============================================================================

/**
 * Create or verify the echo agent exists.
 * Idempotent - safe to call multiple times.
 */
export function setupEchoAgent() {
  const agentId = config.agentId;

  // Try to get existing agent
  const getRes = http.get(`${config.apiUrl}/agents/${agentId}`, jsonHeaders);

  if (getRes.status === 200) {
    console.log(`Using existing agent: ${agentId}`);
    return JSON.parse(getRes.body).agent;
  }

  // Create new agent
  const createRes = http.post(
    `${config.apiUrl}/agents`,
    JSON.stringify({
      agent: {
        id: agentId,
        name: 'Bench Echo Agent',
        origin_url: config.agentUrl,
        webhook_path: '/webhook',
      context: {
        strategy: 'last_n',
        config: { limit: 10 }
      },
        timeout_ms: 30000,
        status: 'enabled',
      },
    }),
    jsonHeaders
  );

  check(createRes, {
    'created echo agent': (res) => res.status === 201,
  });

  if (createRes.status !== 201) {
    throw new Error(`Failed to create agent: ${createRes.status} ${createRes.body}`);
  }

  console.log(`Created new agent: ${agentId}`);
  return JSON.parse(createRes.body).agent;
}

// ============================================================================
// Participant Management
// ============================================================================

/**
 * Generate a unique participant ID for this benchmark run.
 * Uses random UUID to ensure even distribution across storage slots.
 */
export function generateParticipantId(prefix, vuId) {
  // Generate random UUID to avoid hash collisions on storage slots
  const uuid = crypto.randomUUID();
  return `${prefix}-${uuid}`;
}

// ============================================================================
// Session Management
// ============================================================================

/**
 * Create a new session between user and agent.
 */
export function createSession(userId, agentId, metadata = {}) {
  const res = http.post(
    `${config.apiUrl}/sessions`,
    JSON.stringify({
      user_id: userId,
      agent_id: agentId,
      metadata: { ...metadata, bench: true, run_id: config.runId },
    }),
    jsonHeaders
  );

  check(res, {
    'created session': (r) => r.status === 201,
  });

  if (res.status !== 201) {
    throw new Error(`Failed to create session: ${res.status} ${res.body}`);
  }

  return JSON.parse(res.body).session;
}

// ============================================================================
// WebSocket Utilities
// ============================================================================

/**
 * Build WebSocket URL with user authentication.
 */
export function buildWsUrl(userId) {
  const encoded = encodeURIComponent(userId);
  return `${config.wsUrl}?user_id=${encoded}&vsn=2.0.0`;
}

/**
 * Build session topic string.
 */
export function sessionTopic(sessionId) {
  return `session:${sessionId}`;
}

/**
 * Encode Phoenix channel message.
 */
export function encode(event) {
  return JSON.stringify(event);
}

/**
 * Decode Phoenix channel message.
 */
export function decode(raw) {
  try {
    return JSON.parse(raw);
  } catch (_err) {
    return null;
  }
}

/**
 * Create a Phoenix channel join message.
 */
export function joinMessage(topic, joinRef, payload = {}) {
  return [`${joinRef}`, `${joinRef}`, topic, 'phx_join', payload];
}

/**
 * Create a Phoenix channel send message.
 */
export function sendMessage(topic, ref, text, metadata = {}) {
  return [
    null,
    `${ref}`,
    topic,
    'send',
    {
      content: {
        kind: 'text',
        content: { text },
        metadata,
      },
    },
  ];
}

/**
 * Check if a frame is a join reply.
 */
export function isJoinReply(frame, joinRef, topic) {
  if (!Array.isArray(frame) || frame.length < 5) {
    return false;
  }
  const [_joinRefMsg, refMsg, topicMsg, eventMsg] = frame;
  return eventMsg === 'phx_reply' && refMsg === `${joinRef}` && topicMsg === topic;
}

/**
 * Check if a frame is a message event.
 */
export function isMessageEvent(frame, topic) {
  if (!Array.isArray(frame) || frame.length < 5) {
    return false;
  }
  const [_joinRefMsg, _refMsg, topicMsg, eventMsg] = frame;
  return eventMsg === 'message' && topicMsg === topic;
}

// ============================================================================
// Cleanup
// ============================================================================

/**
 * Delete a resource (session or participant).
 */
export function safeDelete(url) {
  const res = http.del(url, null, jsonHeaders);
  if (res.status !== 204 && res.status !== 404) {
    console.error(`Cleanup ${url} failed with status=${res.status}`);
  }
}

/**
 * Delete a session.
 */
export function deleteSession(sessionId) {
  safeDelete(`${config.apiUrl}/sessions/${sessionId}`);
}

// ============================================================================
// Timing Utilities
// ============================================================================

export function nowMs() {
  return Date.now();
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
