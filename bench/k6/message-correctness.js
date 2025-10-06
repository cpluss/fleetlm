/**
 * FleetLM Message Correctness Benchmark
 *
 * Verifies that every message sent by a user session is observed back on the
 * websocket stream (no loss) and that the roundtrip completes within the
 * configured timeout.
 *
 * Key behaviours:
 * - Reuses a dedicated session per VU to avoid create/delete churn.
 * - Sends messages with flow control (configurable pipeline depth).
 * - Tracks message acks, broadcasts, and roundtrip latency per client ref.
 * - Fails loudly when any message is missing.
 *
 * Usage:
 *   k6 run bench/k6/message-correctness.js
 *   k6 run -e VUS=10 -e MESSAGES=20 bench/k6/message-correctness.js
 *   k6 run -e PIPELINE_DEPTH=2 bench/k6/message-correctness.js
 */

import ws from 'k6/ws';
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
// Configuration helpers
// ============================================================================

const defaultMessagesPerIteration = Number(__ENV.MESSAGES || 10);
const defaultPipelineDepth = Math.max(Number(__ENV.PIPELINE_DEPTH || 1), 1);

const vuState = new Map();

function getVuState(vuId) {
  if (!vuState.has(vuId)) {
    vuState.set(vuId, {
      lastSeq: 0,
    });
  }
  return vuState.get(vuId);
}

function configuredVus() {
  // CLI flags override exported options, but we defensively check env.
  return Number(__ENV.VUS || options.vus || 5);
}

// ============================================================================
// Test Configuration
// ============================================================================

export const options = {
  vus: Number(__ENV.VUS || 5),
  iterations: Number(__ENV.ITERATIONS || 10),
  setupTimeout: '60s',
  teardownTimeout: '60s',
  thresholds: {
    message_correctness_rate: ['rate==1.0'], // MUST be 100%
    messages_lost: ['count==0'], // MUST be zero
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  const vus = configuredVus();
  const messagesPerIter = defaultMessagesPerIteration;
  const pipelineDepth = defaultPipelineDepth;

  console.log('Setting up message correctness benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`Configured VUs: ${vus}`);
  console.log(`Iterations (per CLI/options): ${options.iterations}`);
  console.log(`Messages per iteration: ${messagesPerIter}`);
  console.log(`Pipeline depth: ${pipelineDepth}`);
  console.log('Threshold: 100% message delivery (zero loss)');

  const agent = lib.setupEchoAgent();

  const sessions = {};

  for (let vu = 1; vu <= vus; vu++) {
    const userId = lib.generateParticipantId('user', vu);
    try {
      const session = lib.createSession(userId, agent.id, {
        bench: true,
        run_id: lib.config.runId,
        scenario: 'message_correctness',
        vu,
      });

      sessions[vu] = {
        sessionId: session.id,
        userId,
      };
    } catch (error) {
      console.error(`Failed to create session for VU${vu}: ${error.message}`);
      throw error;
    }
  }

  console.log(`Setup complete: ${Object.keys(sessions).length} sessions ready`);

  return {
    agentId: agent.id,
    runId: lib.config.runId,
    sessions,
    messagesPerIter,
    pipelineDepth,
  };
}

// ============================================================================
// Main Test
// ============================================================================

export default function (data) {
  const vuId = __VU;
  const iteration = __ITER;
  const state = getVuState(vuId);
  const sessionData = data.sessions?.[vuId];

  if (!sessionData) {
    console.error(`VU${vuId}: no pre-created session found; skipping iteration ${iteration}`);
    return;
  }

  const messagesToSend = Number(__ENV.MESSAGES || data.messagesPerIter || defaultMessagesPerIteration);
  const pipelineDepth = Math.max(Number(__ENV.PIPELINE_DEPTH || data.pipelineDepth || defaultPipelineDepth), 1);
  const wsUrl = lib.buildWsUrl(sessionData.userId);
  const topic = lib.sessionTopic(sessionData.sessionId);

  const sentMessages = new Map(); // clientRef => { ref, text, sentAt, matched, error }
  const pendingRefs = new Map(); // ref => clientRef

  let messagesSentCount = 0;
  let matchedCount = 0;
  let refCounter = 1;
  let joined = false;
  let joinRef = `${refCounter++}`;

  ws.connect(
    wsUrl,
    {
      tags: { scenario: 'correctness', vu: vuId, iteration },
    },
    (socket) => {
      socket.on('open', () => {
        const joinPayload = state.lastSeq > 0 ? { last_seq: state.lastSeq } : {};
        socket.send(lib.encode(lib.joinMessage(topic, joinRef, joinPayload)));
      });

      socket.on('message', (raw) => {
        const frame = lib.decode(raw);
        if (!frame) return;

        const [, refMsg, topicMsg, eventMsg, payload] = frame;

        if (lib.isJoinReply(frame, joinRef, topic)) {
          joined = true;
          const history = payload?.response?.messages || payload?.response || [];
          if (Array.isArray(history)) {
            for (const message of history) {
              if (typeof message?.seq === 'number') {
                state.lastSeq = Math.max(state.lastSeq, message.seq);
              }
            }
          }

          sendReadyMessages();
          return;
        }

        if (eventMsg === 'phx_reply' && topicMsg === topic) {
          const status = payload?.status;
          const clientRef = pendingRefs.get(refMsg);

          if (status === 'ok') {
            pendingRefs.delete(refMsg);
            sendReadyMessages();
            return;
          }

         if (status === 'error') {
            pendingRefs.delete(refMsg);
            if (clientRef && sentMessages.has(clientRef)) {
              const record = sentMessages.get(clientRef);
              record.error = payload?.response || payload?.reason || 'unknown_error';
            }

            console.error(
              `VU${vuId} Iter${iteration}: server rejected message ref=${refMsg} reason=${JSON.stringify(payload)}`
            );
            sendReadyMessages();
            return;
          }
        }

        if (lib.isMessageEvent(frame, topic)) {
          messagesReceived.add(1);

          const seq = payload?.seq;
          if (typeof seq === 'number') {
            state.lastSeq = Math.max(state.lastSeq, seq);
          }

          const clientRef = payload?.content?.client_ref;

          if (clientRef && sentMessages.has(clientRef)) {
            const record = sentMessages.get(clientRef);
            if (!record.matched) {
              record.matched = true;
              matchedCount++;
              pendingRefs.delete(record.ref);

              const elapsed = lib.nowMs() - record.sentAt;
              roundtripLatency.add(elapsed);
              messagesMatched.add(1);
              messageCorrectnessRate.add(true);
            }
          }

          if (matchedCount === messagesToSend) {
            socket.close();
          } else {
            sendReadyMessages();
          }

          return;
        }

        if (eventMsg === 'backpressure' && topicMsg === topic) {
          console.warn(
            `VU${vuId} Iter${iteration}: received backpressure notice ${JSON.stringify(payload)}`
          );
        }
      });

      socket.on('error', (e) => {
        console.error(`VU${vuId} Iter${iteration}: WebSocket error - ${e}`);
      });

      socket.on('close', () => {
        const lost = [];
        for (const [clientRef, record] of sentMessages.entries()) {
          if (!record.matched) {
            lost.push({ clientRef, text: record.text, error: record.error });
          }
        }

        if (lost.length > 0) {
          messagesLost.add(lost.length);
          for (const entry of lost) {
            const reason = entry.error ? ` (error: ${JSON.stringify(entry.error)})` : '';
            console.error(
              `VU${vuId} Iter${iteration}: lost message "${entry.text}" ref=${entry.clientRef}${reason}`
            );
            messageCorrectnessRate.add(false);
          }
        }
      });

      socket.setTimeout(() => {
        if (matchedCount !== messagesToSend) {
          const remaining = messagesToSend - matchedCount;
          console.error(
            `VU${vuId} Iter${iteration}: timeout waiting for ${remaining} messages (matched ${matchedCount}/${messagesToSend})`
          );
        }
        socket.close();
      }, 30000);

      function sendReadyMessages() {
        if (!joined) return;

        while (messagesSentCount < messagesToSend && pendingRefs.size < pipelineDepth) {
          const messageIndex = messagesSentCount;
          const clientRef = `${sessionData.userId}-iter${iteration}-msg${messageIndex}-${lib.nowMs()}`;
          const ref = `${refCounter++}`;
          const text = `correctness test message ${messageIndex}`;

          const now = lib.nowMs();
          sentMessages.set(clientRef, {
            ref,
            text,
            sentAt: now,
            matched: false,
          });
          pendingRefs.set(ref, clientRef);

          const payload = [
            null,
            ref,
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
                  sequence: messageIndex,
                  run_id: data.runId,
                },
              },
            },
          ];

          socket.send(lib.encode(payload));
          messagesSent.add(1);
          messagesSentCount++;
        }
      }
    }
  );
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  if (data.sessions) {
    const sessionEntries = Object.values(data.sessions);
    console.log(`Cleaning up ${sessionEntries.length} sessions...`);
    for (const entry of sessionEntries) {
      lib.deleteSession(entry.sessionId);
    }
  }

  console.log('\nMessage Correctness Results');
  console.log('===========================');
  console.log(`Run ID: ${data.runId}`);
  console.log('Expected: 100% message delivery (zero loss)');
  console.log('Check metrics above for pass/fail thresholds.');
}
