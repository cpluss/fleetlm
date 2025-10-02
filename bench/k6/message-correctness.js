/**
 * FleetLM Message Correctness Benchmark
 *
 * Tests that EVERY message sent gets a response - zero data loss.
 *
 * This benchmark:
 * - Sends N messages per session
 * - Waits for ALL responses before disconnecting
 * - Tracks each message by unique ID
 * - Reports 100% success or fails with details
 *
 * Usage:
 *   k6 run bench/k6/message-correctness.js
 *   k6 run -e VUS=10 -e MESSAGES=20 bench/k6/message-correctness.js
 */

import ws from 'k6/ws';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const messagesSent = new Counter('messages_sent');
const messagesReceived = new Counter('messages_received');
const messagesMatched = new Counter('messages_matched');
const messagesLost = new Counter('messages_lost');
const messageCorrectnessRate = new Rate('message_correctness_rate');
const roundtripLatency = new Trend('roundtrip_latency_ms', true);

// ============================================================================
// Test Configuration
// ============================================================================

export const options = {
  vus: Number(__ENV.VUS || 5),
  iterations: Number(__ENV.ITERATIONS || 10),
  setupTimeout: '60s',
  thresholds: {
    message_correctness_rate: ['rate==1.0'], // MUST be 100%
    messages_lost: ['count==0'],              // MUST be zero
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up message correctness benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`VUs: ${options.vus}`);
  console.log(`Iterations: ${options.iterations}`);
  console.log('Threshold: 100% message delivery (zero loss)');

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
  const messagesToSend = Number(__ENV.MESSAGES || 10);

  // Create session
  const session = lib.createSession(userId, agentId, {
    vu: vuId,
    iteration,
    type: 'correctness',
  });
  const sessionId = session.id;
  const wsUrl = lib.buildWsUrl(userId);
  const topic = lib.sessionTopic(sessionId);

  // Track all sent messages
  const sentMessages = new Map(); // clientRef => { sentAt, text }
  const receivedMessages = new Set(); // clientRef

  ws.connect(
    wsUrl,
    {
      tags: { scenario: 'correctness', vu: vuId, iteration },
    },
    (socket) => {
      let joined = false;
      let messagesSentCount = 0;
      const joinRef = 1;

      socket.on('open', () => {
        // Join session
        socket.send(lib.encode(lib.joinMessage(topic, joinRef)));

        socket.on('message', (raw) => {
          const frame = lib.decode(raw);
          if (!frame) return;

          // Handle join reply
          if (lib.isJoinReply(frame, joinRef, topic)) {
            joined = true;
            // Start sending messages
            sendAllMessages();
            return;
          }

          // Handle message events
          if (lib.isMessageEvent(frame, topic)) {
            messagesReceived.add(1);
            const [, , , , payload] = frame;
            const content = payload?.content || {};
            const clientRef = content?.client_ref;

            if (clientRef && sentMessages.has(clientRef)) {
              const sentAt = sentMessages.get(clientRef).sentAt;
              roundtripLatency.add(lib.nowMs() - sentAt);
              receivedMessages.add(clientRef);
              messagesMatched.add(1);
            }

            // Check if all messages received
            if (receivedMessages.size === messagesToSend) {
              // Success! All messages accounted for
              for (let i = 0; i < messagesToSend; i++) {
                messageCorrectnessRate.add(true);
              }
              socket.close();
            }
          }
        });

        function sendAllMessages() {
          for (let i = 0; i < messagesToSend; i++) {
            const clientRef = `${userId}-msg${i}-${lib.nowMs()}`;
            const ref = joinRef + i + 1;
            const text = `correctness test message ${i}`;

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
                    sequence: i,
                  },
                },
              },
            ];

            sentMessages.set(clientRef, { sentAt: lib.nowMs(), text });
            socket.send(lib.encode(msg));
            messagesSent.add(1);
            messagesSentCount++;
          }
        }
      });

      socket.on('error', (e) => {
        console.error(`VU${vuId} Iter${iteration}: WebSocket error - ${e}`);
      });

      socket.on('close', () => {
        // Check for message loss
        const lost = messagesToSend - receivedMessages.size;
        if (lost > 0) {
          messagesLost.add(lost);
          console.error(
            `VU${vuId} Iter${iteration}: LOST ${lost}/${messagesToSend} messages!`
          );

          // Report which messages were lost
          for (const [clientRef, data] of sentMessages.entries()) {
            if (!receivedMessages.has(clientRef)) {
              console.error(`  Lost message: "${data.text}" (ref: ${clientRef})`);
              messageCorrectnessRate.add(false);
            }
          }
        }
      });

      // Timeout: give plenty of time for all messages to complete
      // With <1ms latency, even 100 messages should complete in <1 second
      socket.setTimeout(() => {
        const stillWaiting = messagesToSend - receivedMessages.size;
        if (stillWaiting > 0) {
          console.error(
            `VU${vuId} Iter${iteration}: Timeout! Still waiting for ${stillWaiting} messages`
          );
          messagesLost.add(stillWaiting);
          for (let i = 0; i < stillWaiting; i++) {
            messageCorrectnessRate.add(false);
          }
        }
        socket.close();
      }, 30000 / 1000);
    }
  );

  // Clean up
  lib.deleteSession(sessionId);
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  console.log('\nMessage Correctness Results');
  console.log('===========================');
  console.log(`Run ID: ${data.runId}`);
  console.log('');
  console.log('Expected: 100% message delivery (zero loss)');
  console.log('Check thresholds above for pass/fail');
}
