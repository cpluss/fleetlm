/**
 * FleetLM Scenario 2: REST Read/Write Mix
 *
 * Validates HTTP API performance under mixed workload (reads + writes).
 *
 * Profile:
 * - 50 constant VUs hammering the system (no rate limiting)
 * - Each VU alternates: POST → GET → POST → GET...
 * - Duration: 2 minutes
 * - Payload: 1KB JSON content per message
 * - Read: Fetch last 50 messages per session
 *
 * Expected Results:
 * - Throughput: Find the actual ceiling (likely 400-600 req/s)
 * - POST latency: Will increase under load
 * - GET latency: Will increase under load
 * - System should handle pressure gracefully (no crashes/errors)
 *
 * Thresholds (Pass/Fail):
 * PRIMARY (hard fails):
 *   - http_req_failed < 1% (System stability - no crashes/errors)
 * SECONDARY (soft fails):
 *   - p95 < 200ms, p99 < 300ms (Performance can degrade under pressure)
 *
 * Usage:
 *   k6 run bench/k6/2-rest-read-write-mix.js
 *
 *   # Higher load
 *   k6 run -e VUS=100 bench/k6/2-rest-read-write-mix.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const postsTotal = new Counter('posts_total');
const getsTotal = new Counter('gets_total');
const postLatency = new Trend('post_latency', true);
const getLatency = new Trend('get_latency', true);
const messagesReadCount = new Trend('messages_read_count', true);

// ============================================================================
// Test Configuration
// ============================================================================

const vus = Number(__ENV.VUS || 50);
const payloadSize = Number(__ENV.PAYLOAD_SIZE || 1024); // 1KB default
const duration = __ENV.DURATION || '2m';

export const options = {
  setupTimeout: '60s',
  teardownTimeout: '60s',
  scenarios: {
    rest_mix: {
      executor: 'constant-vus',
      vus: vus,
      duration: duration,
    },
  },
  thresholds: {
    // Primary: System stability under pressure
    'http_req_failed': [
      { threshold: 'rate<0.01', abortOnFail: true }, // < 1% errors (no crashes)
    ],
    // Secondary: Performance degradation acceptable under max load
    'http_req_duration': [
      { threshold: 'p(95)<200', abortOnFail: false }, // p95 can degrade under pressure
      { threshold: 'p(99)<300', abortOnFail: false }, // p99 can degrade more
    ],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up REST read/write mix benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`VUs: ${vus} (constant, no rate limiting)`);
  console.log(`Payload size: ${payloadSize} bytes`);
  console.log(`Duration: ${duration}`);

  const agent = lib.setupEchoAgent();
  const agentId = agent.id;

  // Pre-create one session per VU
  console.log(`Pre-creating ${vus} sessions...`);
  const sessions = [];

  for (let i = 0; i < vus; i++) {
    const userId = lib.generateParticipantId('user', i);
    const session = lib.createSession(userId, agentId, {
      vu_slot: i,
      type: 'rest_mix',
      run_id: lib.config.runId,
    });
    sessions.push({
      sessionId: session.id,
      userId: userId,
    });
  }

  console.log(`Setup complete: ${vus} sessions ready`);

  return {
    agentId: agentId,
    runId: lib.config.runId,
    sessions: sessions,
  };
}

// ============================================================================
// Main Test
// ============================================================================

export default function (data) {
  const vuId = __VU;

  // Round-robin across pre-created sessions
  const sessionIndex = (vuId - 1) % data.sessions.length;
  const sessionData = data.sessions[sessionIndex];

  if (!sessionData) {
    console.error(`VU${vuId}: No session found at index ${sessionIndex}`);
    return;
  }

  const sessionId = sessionData.sessionId;
  const userId = sessionData.userId;

  // Generate payload of target size
  const textContent = 'x'.repeat(payloadSize);

  // Alternate between POST and GET
  const iteration = __ITER;
  const isWrite = iteration % 2 === 0;

  if (isWrite) {
    // POST: Append message
    const startPost = Date.now();
    const postRes = http.post(
      `${lib.config.apiUrl}/sessions/${sessionId}/messages`,
      JSON.stringify({
        user_id: userId,
        kind: 'text',
        content: { text: textContent },
        metadata: { bench: true, vu: vuId, iter: iteration },
      }),
      lib.jsonHeaders
    );

    const postDuration = Date.now() - startPost;
    postLatency.add(postDuration);
    postsTotal.add(1);

    check(postRes, {
      'POST status 200': (r) => r.status === 200,
    });

    if (postRes.status !== 200) {
      console.error(`VU${vuId}: POST failed with status ${postRes.status}: ${postRes.body}`);
    }
  } else {
    // GET: Fetch messages
    const startGet = Date.now();
    const getRes = http.get(
      `${lib.config.apiUrl}/sessions/${sessionId}/messages?limit=50`,
      lib.jsonHeaders
    );

    const getDuration = Date.now() - startGet;
    getLatency.add(getDuration);
    getsTotal.add(1);

    const success = check(getRes, {
      'GET status 200': (r) => r.status === 200,
    });

    if (success) {
      try {
        const body = JSON.parse(getRes.body);
        const messageCount = body.messages ? body.messages.length : 0;
        messagesReadCount.add(messageCount);
      } catch (e) {
        console.error(`VU${vuId}: Failed to parse GET response: ${e.message}`);
      }
    } else {
      console.error(`VU${vuId}: GET failed with status ${getRes.status}: ${getRes.body}`);
    }
  }
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  if (data.sessions) {
    console.log(`Cleaning up ${data.sessions.length} sessions...`);
    for (const session of data.sessions) {
      lib.deleteSession(session.sessionId);
    }
  }

  console.log(`\nREST mix test complete (Run ID: ${data.runId})`);
  console.log('Review metrics above for POST vs GET latency breakdown');
}
