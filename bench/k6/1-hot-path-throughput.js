/**
 * FleetLM Scenario 1: Hot-Path Throughput
 *
 * Validates Raft write scalability under burst load.
 *
 * Profile:
 * - 20 concurrent WebSocket sessions (VUs)
 * - Pipeline depth: 5 messages in-flight per VU
 * - Duration: 30s ramp-up → 1m40s steady → 10s ramp-down
 * - Pattern: Send message → Wait for ack → Send next (flow-controlled)
 *
 * Expected Results (M3 Ultra, single node):
 * - Throughput: 18,000-20,000 msg/s
 * - p95 latency: 4-6ms
 * - p99 latency: 10-20ms
 * - Success rate: 99.9%+
 *
 * Thresholds (Pass/Fail):
 * - ack_latency p95 < 10ms (Raft append + broadcast)
 * - ack_latency p99 < 150ms (Target SLA)
 * - Success rate > 99% (acks_received / messages_sent)
 * - Throughput > 10,000 msg/s
 *
 * Usage:
 *   # Default: 20 VUs with pipeline depth of 5
 *   k6 run bench/k6/1-hot-path-throughput.js
 *
 *   # Higher load
 *   k6 run -e PIPELINE_DEPTH=10 -e MAX_VUS=50 bench/k6/1-hot-path-throughput.js
 */

import ws from 'k6/ws';
import { check } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const messagesSent = new Counter('messages_sent');
const acksReceived = new Counter('acks_received');
const messagesReceived = new Counter('messages_received');
const backpressureEvents = new Counter('backpressure_events');
const ackLatency = new Trend('ack_latency', true); // Trend with percentiles

// ============================================================================
// Test Configuration
// ============================================================================

const maxVUs = Number(__ENV.MAX_VUS || 20);
const rampDuration = __ENV.RAMP_DURATION || '30s';
const steadyDuration = __ENV.STEADY_DURATION || '1m40s';
const rampDownDuration = __ENV.RAMP_DOWN_DURATION || '10s';

export const options = {
  setupTimeout: '60s',
  teardownTimeout: '60s',
  scenarios: {
    throughput: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampDuration, target: maxVUs },    // Ramp up
        { duration: steadyDuration, target: maxVUs },  // Steady state
        { duration: rampDownDuration, target: 0 },     // Ramp down
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    // Primary: System stability
    'checks': [
      { threshold: 'rate>0.99', abortOnFail: true }, // 99% success rate (no errors)
    ],
    // Secondary: Performance targets
    'ack_latency': [
      { threshold: 'p(95)<10', abortOnFail: false },  // p95 < 10ms (ideal)
      { threshold: 'p(99)<150', abortOnFail: false }, // p99 < 150ms (SLA)
    ],
    'acks_received': [
      { threshold: 'count>1000000', abortOnFail: false }, // Throughput check
    ],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  const pipelineDepth = Number(__ENV.PIPELINE_DEPTH || 5);
  
  console.log('Setting up message throughput benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`Max VUs: ${maxVUs}`);
  console.log(`Pipeline depth: ${pipelineDepth} (max in-flight per VU)`);
  console.log(`Ramp: ${rampDuration} → Steady: ${steadyDuration} → Down: ${rampDownDuration}`);
  console.log(`Peak capacity: ${maxVUs} VUs × ${pipelineDepth} msgs = ${maxVUs * pipelineDepth} concurrent messages`);

  // Ensure echo agent exists
  const agent = lib.setupEchoAgent();
  const agentId = agent.id;

  // Pre-create sessions for each VU to avoid session creation overhead in main test
  console.log(`Pre-creating ${maxVUs} sessions...`);
  const sessions = {};
  
  for (let vuId = 1; vuId <= maxVUs; vuId++) {
    const userId = lib.generateParticipantId('user', vuId);
    try {
      const session = lib.createSession(userId, agentId, { 
        vu: vuId, 
        type: 'throughput',
        run_id: lib.config.runId 
      });
      sessions[vuId] = {
        sessionId: session.id,
        userId: userId,
      };
    } catch (e) {
      console.error(`Failed to create session for VU${vuId}: ${e.message}`);
      throw e;
    }
  }

  console.log(`Setup complete: ${maxVUs} sessions ready`);

  return {
    agentId: agentId,
    runId: lib.config.runId,
    sessions: sessions,
    pipelineDepth: pipelineDepth,
  };
}

// ============================================================================
// Main Test
// ============================================================================

export default function (data) {
  const vuId = __VU;
  const pipelineDepth = data.pipelineDepth;

  // Retrieve pre-created session for this VU
  const sessionData = data.sessions[vuId];
  if (!sessionData) {
    console.error(`VU${vuId}: No session found in setup data`);
    return;
  }

  const sessionId = sessionData.sessionId;
  const userId = sessionData.userId;
  const wsUrl = lib.buildWsUrl(userId);
  const topic = lib.sessionTopic(sessionId);

  console.log(`VU${vuId}: Starting with pipeline depth ${pipelineDepth} on session ${sessionId}`);

  ws.connect(
    wsUrl,
    {
      tags: { session: sessionId, vu: vuId },
    },
    (socket) => {
      let joined = false;
      let messageSeq = 0;
      const joinRef = 1;

      // Track pending acks for flow control + latency measurement
      const pendingRefs = new Map(); // ref -> timestamp

      socket.on('open', () => {
        // Join the session channel
        socket.send(lib.encode(lib.joinMessage(topic, joinRef)));

        // Set timeout for join
        socket.setTimeout(() => {
          if (!joined) {
            console.error(`VU${vuId}: Failed to join after 10s`);
            socket.close();
          }
        }, 10000);
      });

      socket.on('message', (raw) => {
        const frame = lib.decode(raw);
        if (!frame) return;

        const [, refMsg, topicMsg, eventMsg, payload] = frame;

        // Handle join reply
        if (lib.isJoinReply(frame, joinRef, topic)) {
          joined = true;
          console.log(`VU${vuId}: Joined - pipeline depth ${pipelineDepth}`);
          return;
        }

        // Check if it's an error response
        if (eventMsg === 'phx_reply' && topicMsg === topic && payload?.status === 'error') {
          console.error(`VU${vuId}: Server error:`, JSON.stringify(payload?.response || payload));
          socket.close();
          return;
        }

        // Handle acks - measure latency and remove from pending
        if (eventMsg === 'phx_reply' && topicMsg === topic && payload?.status === 'ok') {
          const sendTime = pendingRefs.get(refMsg);
          if (sendTime) {
            const latency = Date.now() - sendTime;
            ackLatency.add(latency);
            pendingRefs.delete(refMsg);
            acksReceived.add(1);
          }
        }

        // Count message broadcasts
        if (lib.isMessageEvent(frame, topic)) {
          messagesReceived.add(1);
        }

        // Handle backpressure
        if (eventMsg === 'backpressure') {
          backpressureEvents.add(1);
          console.warn(`VU${vuId}: Backpressure - ${payload?.reason}`);
        }
      });

      socket.on('error', (e) => {
        console.error(`VU${vuId}: WebSocket error:`, e);
      });

      socket.on('close', () => {
        if (joined && messageSeq > 0) {
          console.log(`VU${vuId}: Done - sent ${messageSeq} messages, ${pendingRefs.size} pending`);
        }
      });

      // Send messages with flow control - tight loop checking pipeline capacity
      socket.setInterval(() => {
        if (!joined) return;

        // Send as many as we can without exceeding pipeline depth
        while (pendingRefs.size < pipelineDepth) {
          messageSeq++;
          const ref = joinRef + messageSeq;
          const text = `msg ${messageSeq}`;

          const msg = [
            null,
            `${ref}`,
            topic,
            'send',
            {
              content: {
                kind: 'text',
                content: { text },
                metadata: {
                  bench: true,
                  vu: vuId,
                  seq: messageSeq,
                },
              },
            },
          ];

          pendingRefs.set(`${ref}`, Date.now());
          socket.send(lib.encode(msg));
          messagesSent.add(1);
        }
      }, 1); // Check every 1ms - very tight loop

      // Note: Connection stays open until VU is ramped down by k6
      // Success rate = acks_received / messages_sent (should be ~100%)
    }
  );
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  // Clean up sessions
  if (data.sessions) {
    const sessionCount = Object.keys(data.sessions).length;
    console.log(`Cleaning up ${sessionCount} sessions...`);
    for (const vuId in data.sessions) {
      const sessionId = data.sessions[vuId].sessionId;
      lib.deleteSession(sessionId);
    }
  }
  
  console.log(`\nLoad test complete (Run ID: ${data.runId})`);
  console.log('Review metrics above:');
  console.log('  - messages_sent: Total messages sent');
  console.log('  - acks_received: Acks from server');
  console.log('  - messages_received: Message broadcasts');
  console.log('  - Success rate = acks_received / messages_sent');
}
