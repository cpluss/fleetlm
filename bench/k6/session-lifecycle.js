/**
 * FleetLM Session Lifecycle Benchmark
 *
 * Tests realistic end-to-end user journeys:
 * - Create session
 * - Connect WebSocket
 * - Exchange messages
 * - Disconnect cleanly
 *
 * Metrics:
 * - End-to-end latency (create → first message → disconnect)
 * - Session join latency
 * - Message roundtrip time
 * - Cleanup success rate
 *
 * Usage:
 *   k6 run bench/k6/session-lifecycle.js
 *   k6 run -e VUS=20 -e ITERATIONS=100 bench/k6/session-lifecycle.js
 *   k6 run -e MESSAGES_PER_SESSION=5 bench/k6/session-lifecycle.js
 */

import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const lifecycleLatency = new Trend('lifecycle_total_ms', true);
const joinLatency = new Trend('join_latency_ms', true);
const roundtripLatency = new Trend('message_roundtrip_ms', true);
const sessionsCompleted = new Counter('sessions_completed');
const sessionFailures = new Counter('session_failures');
const lifecycleSuccessRate = new Rate('lifecycle_success_rate');

// ============================================================================
// Test Configuration
// ============================================================================

export const options = {
  vus: Number(__ENV.VUS || 10),
  iterations: Number(__ENV.ITERATIONS || 50),
  setupTimeout: '60s',
  thresholds: {
    lifecycle_total_ms: ['p(95)<3000'],
    join_latency_ms: ['p(95)<1000'],
    message_roundtrip_ms: ['p(95)<500'],
    lifecycle_success_rate: ['rate>0.95'],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up session lifecycle benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`VUs: ${options.vus}`);
  console.log(`Iterations per VU: ${options.iterations}`);

  // Ensure echo agent exists
  lib.setupEchoAgent();

  return {
    agentId: lib.config.agentId,
    runId: lib.config.runId,
  };
}

// ============================================================================
// Main Test
// ============================================================================

export default function (data) {
  const vuId = __VU;
  const iteration = __ITER;
  const agentId = data.agentId;
  const userId = lib.generateParticipantId(`user-iter${iteration}`, vuId);
  const messagesPerSession = Number(__ENV.MESSAGES_PER_SESSION || 3);

  const lifecycleStart = lib.nowMs();
  let sessionId;
  let success = true;

  try {
    // Create session
    const session = lib.createSession(userId, agentId, {
      vu: vuId,
      iteration,
      type: 'lifecycle',
    });
    sessionId = session.id;

    const wsUrl = lib.buildWsUrl(userId);
    const topic = lib.sessionTopic(sessionId);

    // Connect and exchange messages
    ws.connect(
      wsUrl,
      {
        tags: { session: sessionId, vu: vuId, iteration },
      },
      (socket) => {
        let joined = false;
        let messagesSent = 0;
        let messagesReceived = 0;
        const joinRef = 1;
        const sentTimes = new Map();

        socket.on('open', () => {
          const joinStart = lib.nowMs();

          // Join session
          socket.send(lib.encode(lib.joinMessage(topic, joinRef)));

          socket.on('message', (raw) => {
            const frame = lib.decode(raw);
            if (!frame) return;

            // Handle join reply
            if (lib.isJoinReply(frame, joinRef, topic)) {
              joined = true;
              joinLatency.add(lib.nowMs() - joinStart);

              // Start sending messages once joined
              sendNextMessage();
              return;
            }

            // Handle message events
            if (lib.isMessageEvent(frame, topic)) {
              messagesReceived++;

              const [, , , , payload] = frame;
              const content = payload?.content || {};
              const clientRef = content?.client_ref;

              // Measure roundtrip if we have the ref
              if (clientRef && sentTimes.has(clientRef)) {
                const sentAt = sentTimes.get(clientRef);
                roundtripLatency.add(lib.nowMs() - sentAt);
                sentTimes.delete(clientRef);
              }

              // Send next message or finish
              if (messagesSent < messagesPerSession) {
                sendNextMessage();
              } else {
                // All messages sent and received
                socket.close();
              }
            }
          });

          function sendNextMessage() {
            if (!joined || messagesSent >= messagesPerSession) return;

            const seq = messagesSent;
            const clientRef = `${userId}-${seq}-${lib.nowMs()}`;
            const ref = joinRef + seq + 1;
            const text = `lifecycle message ${seq} from VU${vuId}`;

            const msg = [
              null,
              `${ref}`,
              topic,
              'send',
              {
                content: {
                  kind: 'text',
                  content: {
                    text,
                    client_ref: clientRef,
                  },
                  metadata: {
                    vu: vuId,
                    iteration,
                    seq,
                  },
                },
              },
            ];

            sentTimes.set(clientRef, lib.nowMs());
            socket.send(lib.encode(msg));
            messagesSent++;
          }
        });

        socket.on('error', (e) => {
          success = false;
          sessionFailures.add(1);
          console.error(`VU${vuId} Iter${iteration}: Error - ${e}`);
        });

        socket.on('close', () => {
          // Lifecycle complete
          if (success && messagesSent === messagesPerSession) {
            lifecycleLatency.add(lib.nowMs() - lifecycleStart);
            sessionsCompleted.add(1);
            lifecycleSuccessRate.add(true);
          } else {
            lifecycleSuccessRate.add(false);
          }
        });

        // Timeout safety
        socket.setTimeout(() => {
          success = false;
          sessionFailures.add(1);
          socket.close();
        }, 30000 / 1000);
      }
    );

    // Clean up
    lib.deleteSession(sessionId);
  } catch (e) {
    success = false;
    sessionFailures.add(1);
    lifecycleSuccessRate.add(false);
    console.error(`VU${vuId} Iter${iteration}: Failed - ${e.message}`);

    // Attempt cleanup
    if (sessionId) {
      lib.deleteSession(sessionId);
    }
  }

  // Brief pause between iterations
  sleep(0.5);
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  console.log('Session lifecycle benchmark complete');
  console.log(`Run ID: ${data.runId}`);
}
