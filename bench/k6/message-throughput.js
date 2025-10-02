/**
 * FleetLM Message Throughput Benchmark
 *
 * Tests message processing capacity with rapid-fire messages.
 *
 * Metrics:
 * - Messages per second (total and per session)
 * - Message append latency (client → server → broadcast)
 * - Agent webhook latency
 * - Backpressure behavior
 *
 * Usage:
 *   k6 run bench/k6/message-throughput.js
 *   k6 run -e VUS=10 -e SEND_INTERVAL=100 bench/k6/message-throughput.js
 *   k6 run -e VUS=20 -e DURATION=5m bench/k6/message-throughput.js
 */

import ws from 'k6/ws';
import { check } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const messagesSent = new Counter('messages_sent');
const messagesReceived = new Counter('messages_received');
const appendLatency = new Trend('append_latency_ms', true);
const backpressureEvents = new Counter('backpressure_events');
const messageFailures = new Counter('message_failures');
const messageSuccessRate = new Rate('message_success_rate');

// ============================================================================
// Test Configuration
// ============================================================================

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration: __ENV.DURATION || '1m',
  setupTimeout: '60s',
  thresholds: {
    append_latency_ms: ['p(95)<500', 'p(99)<1000'],
    message_success_rate: ['rate>0.95'],
    backpressure_events: ['count<100'],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up message throughput benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`VUs: ${options.vus}`);
  console.log(`Duration: ${options.duration}`);
  console.log(`Send interval: ${__ENV.SEND_INTERVAL || 1000}ms`);

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
  const agentId = data.agentId;
  const userId = lib.generateParticipantId('user', vuId);
  const sendInterval = Number(__ENV.SEND_INTERVAL || 1000); // milliseconds

  // Create session
  let session;
  try {
    session = lib.createSession(userId, agentId, { vu: vuId, type: 'throughput' });
  } catch (e) {
    messageFailures.add(1);
    console.error(`VU${vuId}: Failed to create session: ${e.message}`);
    return;
  }

  const sessionId = session.id;
  const wsUrl = lib.buildWsUrl(userId);
  const topic = lib.sessionTopic(sessionId);

  // Track in-flight messages for latency measurement
  const inFlight = new Map();

  ws.connect(
    wsUrl,
    {
      tags: { session: sessionId, vu: vuId },
    },
    (socket) => {
      let joined = false;
      let messageSeq = 0;
      const joinRef = 1;

      socket.on('open', () => {
        // Join the session channel
        socket.send(lib.encode(lib.joinMessage(topic, joinRef)));

        // Set timeout for join
        socket.setTimeout(() => {
          if (!joined) {
            messageFailures.add(1);
            messageSuccessRate.add(false);
            socket.close();
          }
        }, 10000 / 1000);

        socket.on('message', (raw) => {
          const frame = lib.decode(raw);
          if (!frame) return;

          // Handle join reply
          if (lib.isJoinReply(frame, joinRef, topic)) {
            joined = true;
            return;
          }

          // Handle message events
          if (lib.isMessageEvent(frame, topic)) {
            messagesReceived.add(1);

            const [, , , , payload] = frame;
            const content = payload?.content || {};
            const clientRef = content?.client_ref;

            // Calculate latency if we have the client_ref
            if (clientRef && inFlight.has(clientRef)) {
              const sentAt = inFlight.get(clientRef);
              appendLatency.add(lib.nowMs() - sentAt);
              inFlight.delete(clientRef);
              messageSuccessRate.add(true);
            }
          }

          // Handle backpressure
          if (Array.isArray(frame) && frame[3] === 'backpressure') {
            backpressureEvents.add(1);
            const [, , , , payload] = frame;
            console.log(`VU${vuId}: Backpressure - ${payload?.reason}`);
          }
        });
      });

      socket.on('error', (e) => {
        messageFailures.add(1);
        messageSuccessRate.add(false);
      });

      // Send messages at configured interval
      socket.setInterval(() => {
        if (!joined) return;

        const clientRef = `${userId}-${vuId}-${messageSeq}-${lib.nowMs()}`;
        const ref = joinRef + messageSeq + 1;
        const text = `throughput test message ${messageSeq} from VU${vuId}`;

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
                bench: true,
                vu: vuId,
                seq: messageSeq,
              },
            },
          },
        ];

        inFlight.set(clientRef, lib.nowMs());
        socket.send(lib.encode(msg));
        messagesSent.add(1);
        messageSeq++;
      }, sendInterval / 1000);

      // Clean up stale in-flight messages
      socket.setInterval(() => {
        if (!joined) return;

        // If too many in-flight, something is wrong
        if (inFlight.size > 100) {
          messageFailures.add(inFlight.size);
          inFlight.clear();
        }
      }, 5000 / 1000);

      // Keep connection alive for test duration
      const runtimeMs = Number(__ENV.RUNTIME_MS || 60000);
      socket.setTimeout(() => {
        socket.close();
      }, runtimeMs / 1000);
    }
  );
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  console.log('Message throughput benchmark complete');
  console.log(`Run ID: ${data.runId}`);
}
