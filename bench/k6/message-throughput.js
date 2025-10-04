/**
 * FleetLM Message Throughput Benchmark
 *
 * Finds the ACTUAL sustainable message throughput using flow control.
 * Each VU sends a message, waits for ack, then sends the next (pipelined with configurable depth).
 *
 * Architecture:
 * - Sessions are pre-created during setup (one per VU)
 * - VUs ramp up gradually to find capacity under increasing load
 * - Each VU uses flow control: send → wait for ack → send next
 * - Configurable pipeline depth to allow N in-flight messages
 * - Measures SUSTAINABLE throughput, not just flooding
 *
 * Metrics:
 * - messages_sent: Total messages sent by all VUs
 * - acks_received: Server acks received (successful appends)
 * - messages_received: Message broadcasts from agent
 * - backpressure_events: Times server pushed back
 * - Success rate: Should be ~100% with proper flow control
 *
 * Usage:
 *   # Default: 10 VUs with pipeline depth of 5
 *   k6 run bench/k6/message-throughput.js
 *   
 *   # More aggressive: higher pipeline depth
 *   k6 run -e PIPELINE_DEPTH=10 -e MAX_VUS=20 bench/k6/message-throughput.js
 *   
 *   # Conservative: pipeline depth of 1 (strict send/ack)
 *   k6 run -e PIPELINE_DEPTH=1 bench/k6/message-throughput.js
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

// ============================================================================
// Test Configuration
// ============================================================================

const maxVUs = Number(__ENV.MAX_VUS || 10);
const rampDuration = __ENV.RAMP_DURATION || '30s';
const steadyDuration = __ENV.STEADY_DURATION || '1m';
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
    // No hard thresholds - this is a load test to find breaking points
    // Manually compare messages_sent vs acks_received to see success rate
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
      
      // Track pending acks for flow control
      const pendingRefs = new Set();

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

        // Handle acks - remove from pending to allow next message
        if (eventMsg === 'phx_reply' && topicMsg === topic && payload?.status === 'ok') {
          pendingRefs.delete(refMsg);
          acksReceived.add(1);
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

          pendingRefs.add(`${ref}`);
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
