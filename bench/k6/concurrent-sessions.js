/**
 * FleetLM Concurrent Sessions Benchmark
 *
 * Tests the system's ability to handle many concurrent WebSocket sessions.
 *
 * Metrics:
 * - Maximum concurrent sessions before degradation
 * - Session creation latency under load
 * - WebSocket connection stability
 * - Memory usage per session
 *
 * Usage:
 *   k6 run bench/k6/concurrent-sessions.js
 *   k6 run -e VUS=100 -e DURATION=5m bench/k6/concurrent-sessions.js
 *   k6 run -e VUS=500 -e API_URL=https://staging.example.com/api bench/k6/concurrent-sessions.js
 */

import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend, Gauge } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const sessionCreationLatency = new Trend('session_creation_ms', true);
const joinLatency = new Trend('ws_join_ms', true);
const activeConnections = new Gauge('active_ws_connections');
const connectionFailures = new Counter('connection_failures');
const messagesReceived = new Counter('messages_received');

// ============================================================================
// Test Configuration
// ============================================================================

export const options = {
  vus: Number(__ENV.VUS || 50),
  duration: __ENV.DURATION || '2m',
  setupTimeout: '60s',
  thresholds: {
    session_creation_ms: ['p(95)<1000'],
    ws_join_ms: ['p(95)<2000'],
    connection_failures: ['count<10'],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up concurrent sessions benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`Target VUs: ${options.vus}`);
  console.log(`Duration: ${options.duration}`);

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

  // Create session (no need to pre-create participants)
  const sessionStart = lib.nowMs();
  let session;
  try {
    session = lib.createSession(userId, agentId, { vu: vuId, type: 'concurrent' });
    sessionCreationLatency.add(lib.nowMs() - sessionStart);
  } catch (e) {
    connectionFailures.add(1);
    console.error(`VU${vuId}: Failed to create session: ${e.message}`);
    return;
  }

  const sessionId = session.id;
  const wsUrl = lib.buildWsUrl(userId);
  const topic = lib.sessionTopic(sessionId);

  // Connect to WebSocket and keep alive
  ws.connect(
    wsUrl,
    {
      tags: { session: sessionId, vu: vuId },
    },
    (socket) => {
      let joined = false;
      let messageCount = 0;
      const joinRef = 1;

      socket.on('open', () => {
        const joinStart = lib.nowMs();

        // Join the session channel
        socket.send(lib.encode(lib.joinMessage(topic, joinRef)));

        socket.on('message', (raw) => {
          const frame = lib.decode(raw);
          if (!frame) return;

          // Handle join reply
          if (lib.isJoinReply(frame, joinRef, topic)) {
            joined = true;
            joinLatency.add(lib.nowMs() - joinStart);
            activeConnections.add(1);
            return;
          }

          // Handle message events
          if (lib.isMessageEvent(frame, topic)) {
            messageCount++;
            messagesReceived.add(1);
          }
        });
      });

      socket.on('error', (e) => {
        connectionFailures.add(1);
        console.error(`VU${vuId}: WebSocket error: ${e}`);
      });

      socket.on('close', () => {
        activeConnections.add(-1);
      });

      // Send a test message every 30 seconds to keep connection warm
      socket.setInterval(() => {
        if (!joined) return;

        const ref = joinRef + messageCount + 1;
        const msg = lib.sendMessage(
          topic,
          ref,
          `ping from VU${vuId}`,
          { vu: vuId, seq: messageCount }
        );
        socket.send(lib.encode(msg));
      }, 30000 / 1000);

      // Keep connection open for most of the test duration
      const keepAliveMs = Number(__ENV.KEEP_ALIVE_MS || 60000);
      socket.setTimeout(() => {
        socket.close();
      }, keepAliveMs / 1000);
    }
  );

  // Small sleep between iterations
  sleep(1);
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  console.log('Benchmark complete');
  console.log(`Run ID: ${data.runId}`);
  console.log('Note: Sessions and participants created during this test may still exist.');
  console.log('Use the FleetLM API to clean them up if needed.');
}
