/**
 * FleetLM Mixed Workload Benchmark
 *
 * Simulates realistic production load with multiple concurrent behaviors:
 * - Long-lived sessions with occasional messages
 * - Rapid message bursts
 * - Session churn (create → use → disconnect)
 *
 * Metrics:
 * - Overall system performance under mixed load
 * - Resource contention effects
 * - Sustained throughput
 *
 * Usage:
 *   k6 run bench/k6/mixed-workload.js
 *   k6 run -e DURATION=10m -e LONG_LIVED_VUS=50 bench/k6/mixed-workload.js
 *   k6 run -e PRESET=stress bench/k6/mixed-workload.js
 */

import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend, Gauge, Rate } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const messagesSent = new Counter('messages_sent');
const messagesReceived = new Counter('messages_received');
const appendLatency = new Trend('append_latency_ms', true);
const activeConnections = new Gauge('active_connections');
const sessionChurnRate = new Counter('session_churn_total');
const backpressureEvents = new Counter('backpressure_events');
const messageSuccessRate = new Rate('message_success_rate');

// ============================================================================
// Presets
// ============================================================================

const presets = {
  light: {
    longLivedVUs: 10,
    burstVUs: 5,
    churnVUs: 3,
    duration: '2m',
  },
  standard: {
    longLivedVUs: 30,
    burstVUs: 15,
    churnVUs: 10,
    duration: '5m',
  },
  stress: {
    longLivedVUs: 100,
    burstVUs: 50,
    churnVUs: 25,
    duration: '10m',
  },
};

const preset = presets[__ENV.PRESET || 'light'];

// ============================================================================
// Test Configuration
// ============================================================================

export const options = {
  setupTimeout: '60s',
  scenarios: {
    // Long-lived sessions with occasional messages
    long_lived: {
      executor: 'constant-vus',
      exec: 'longLivedSession',
      vus: Number(__ENV.LONG_LIVED_VUS || preset.longLivedVUs),
      duration: __ENV.DURATION || preset.duration,
      tags: { scenario: 'long_lived' },
    },
    // Burst messaging on existing sessions
    burst_messages: {
      executor: 'constant-vus',
      exec: 'burstMessages',
      vus: Number(__ENV.BURST_VUS || preset.burstVUs),
      duration: __ENV.DURATION || preset.duration,
      tags: { scenario: 'burst' },
    },
    // Continuous session churn
    session_churn: {
      executor: 'constant-vus',
      exec: 'sessionChurn',
      vus: Number(__ENV.CHURN_VUS || preset.churnVUs),
      duration: __ENV.DURATION || preset.duration,
      tags: { scenario: 'churn' },
    },
  },
  thresholds: {
    append_latency_ms: ['p(95)<1000'],
    message_success_rate: ['rate>0.90'],
    backpressure_events: ['count<500'],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up mixed workload benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`Preset: ${__ENV.PRESET || 'light'}`);
  console.log(`Duration: ${options.scenarios.long_lived.duration}`);
  console.log(`Long-lived VUs: ${options.scenarios.long_lived.vus}`);
  console.log(`Burst VUs: ${options.scenarios.burst_messages.vus}`);
  console.log(`Churn VUs: ${options.scenarios.session_churn.vus}`);

  // Ensure echo agent exists
  lib.setupEchoAgent();

  return {
    agentId: lib.config.agentId,
    runId: lib.config.runId,
  };
}

// ============================================================================
// Scenario 1: Long-Lived Sessions
// ============================================================================

export function longLivedSession(data) {
  const vuId = __VU;
  const agentId = data.agentId;
  const userId = lib.generateParticipantId('long-lived', vuId);

  // Create session
  const session = lib.createSession(userId, agentId, { scenario: 'long_lived', vu: vuId });
  const sessionId = session.id;
  const wsUrl = lib.buildWsUrl(userId);
  const topic = lib.sessionTopic(sessionId);

  ws.connect(wsUrl, { tags: { scenario: 'long_lived', vu: vuId } }, (socket) => {
    let joined = false;
    let messageSeq = 0;
    const joinRef = 1;
    const inFlight = new Map();

    socket.on('open', () => {
      socket.send(lib.encode(lib.joinMessage(topic, joinRef)));
      activeConnections.add(1);

      socket.on('message', (raw) => {
        const frame = lib.decode(raw);
        if (!frame) return;

        if (lib.isJoinReply(frame, joinRef, topic)) {
          joined = true;
          return;
        }

        if (lib.isMessageEvent(frame, topic)) {
          messagesReceived.add(1);
          const [, , , , payload] = frame;
          const clientRef = payload?.content?.client_ref;

          if (clientRef && inFlight.has(clientRef)) {
            appendLatency.add(lib.nowMs() - inFlight.get(clientRef));
            inFlight.delete(clientRef);
            messageSuccessRate.add(true);
          }
        }
      });
    });

    socket.on('close', () => {
      activeConnections.add(-1);
    });

    // Send message every 20-40 seconds (low frequency)
    socket.setInterval(() => {
      if (!joined) return;

      const clientRef = `ll-${userId}-${messageSeq}-${lib.nowMs()}`;
      const ref = joinRef + messageSeq + 1;
      const msg = lib.sendMessage(
        topic,
        ref,
        `long-lived message ${messageSeq}`,
        { scenario: 'long_lived', seq: messageSeq, client_ref: clientRef }
      );

      inFlight.set(clientRef, lib.nowMs());
      socket.send(lib.encode(msg));
      messagesSent.add(1);
      messageSeq++;
    }, (20000 + Math.random() * 20000) / 1000);

    // Keep alive for duration
    socket.setTimeout(() => {
      socket.close();
    }, 120000 / 1000);
  });

  sleep(1);
}

// ============================================================================
// Scenario 2: Burst Messages
// ============================================================================

export function burstMessages(data) {
  const vuId = __VU;
  const agentId = data.agentId;
  const userId = lib.generateParticipantId('burst', vuId);

  // Create session
  const session = lib.createSession(userId, agentId, { scenario: 'burst', vu: vuId });
  const sessionId = session.id;
  const wsUrl = lib.buildWsUrl(userId);
  const topic = lib.sessionTopic(sessionId);

  ws.connect(wsUrl, { tags: { scenario: 'burst', vu: vuId } }, (socket) => {
    let joined = false;
    let messageSeq = 0;
    const joinRef = 1;
    const inFlight = new Map();

    socket.on('open', () => {
      socket.send(lib.encode(lib.joinMessage(topic, joinRef)));

      socket.on('message', (raw) => {
        const frame = lib.decode(raw);
        if (!frame) return;

        if (lib.isJoinReply(frame, joinRef, topic)) {
          joined = true;
          return;
        }

        if (lib.isMessageEvent(frame, topic)) {
          messagesReceived.add(1);
          const [, , , , payload] = frame;
          const clientRef = payload?.content?.client_ref;

          if (clientRef && inFlight.has(clientRef)) {
            appendLatency.add(lib.nowMs() - inFlight.get(clientRef));
            inFlight.delete(clientRef);
            messageSuccessRate.add(true);
          }
        }

        if (Array.isArray(frame) && frame[3] === 'backpressure') {
          backpressureEvents.add(1);
        }
      });
    });

    // Rapid-fire messages (every 100-500ms)
    socket.setInterval(() => {
      if (!joined) return;

      const clientRef = `burst-${userId}-${messageSeq}-${lib.nowMs()}`;
      const ref = joinRef + messageSeq + 1;
      const msg = lib.sendMessage(
        topic,
        ref,
        `burst ${messageSeq}`,
        { scenario: 'burst', seq: messageSeq, client_ref: clientRef }
      );

      inFlight.set(clientRef, lib.nowMs());
      socket.send(lib.encode(msg));
      messagesSent.add(1);
      messageSeq++;
    }, (100 + Math.random() * 400) / 1000);

    socket.setTimeout(() => {
      socket.close();
    }, 60000 / 1000);
  });

  sleep(2);
}

// ============================================================================
// Scenario 3: Session Churn
// ============================================================================

export function sessionChurn(data) {
  const vuId = __VU;
  const iteration = __ITER;
  const agentId = data.agentId;
  const userId = lib.generateParticipantId(`churn-${iteration}`, vuId);

  try {
    // Create session
    const session = lib.createSession(userId, agentId, {
      scenario: 'churn',
      vu: vuId,
      iteration,
    });
    const sessionId = session.id;
    const wsUrl = lib.buildWsUrl(userId);
    const topic = lib.sessionTopic(sessionId);

    // Quick session: join, send a few messages, disconnect
    ws.connect(wsUrl, { tags: { scenario: 'churn' } }, (socket) => {
      let joined = false;
      let messagesSentCount = 0;
      const messagesToSend = 2 + Math.floor(Math.random() * 3); // 2-4 messages
      const joinRef = 1;

      socket.on('open', () => {
        socket.send(lib.encode(lib.joinMessage(topic, joinRef)));

        socket.on('message', (raw) => {
          const frame = lib.decode(raw);
          if (!frame) return;

          if (lib.isJoinReply(frame, joinRef, topic)) {
            joined = true;
            sendMessages();
            return;
          }

          if (lib.isMessageEvent(frame, topic)) {
            messagesReceived.add(1);
          }
        });

        function sendMessages() {
          for (let i = 0; i < messagesToSend; i++) {
            const ref = joinRef + i + 1;
            const msg = lib.sendMessage(topic, ref, `churn message ${i}`, {
              scenario: 'churn',
              seq: i,
            });
            socket.send(lib.encode(msg));
            messagesSent.add(1);
            messagesSentCount++;
          }

          // Disconnect after sending
          setTimeout(() => socket.close(), 2000);
        }
      });
    });

    sessionChurnRate.add(1);

    // Clean up
    lib.deleteSession(sessionId);
  } catch (e) {
    console.error(`Churn VU${vuId} Iter${iteration}: ${e.message}`);
  }

  // Pause between churn iterations
  sleep(3 + Math.random() * 5);
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  console.log('Mixed workload benchmark complete');
  console.log(`Run ID: ${data.runId}`);
}
