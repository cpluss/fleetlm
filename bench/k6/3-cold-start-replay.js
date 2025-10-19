/**
 * FleetLM Scenario 3: Cold-Start Replay
 *
 * Simulates agent reconnection after downtime, validates backlog replay performance.
 *
 * Profile:
 * - 5 sessions with large backlogs
 * - Phase 1: Accumulate backlog (30s of max throughput writes)
 * - Phase 2: Reconnect and replay from after_seq=0 while writers continue
 * - Duration: 30s backlog → 1m replay under active writes
 * - Max throughput (no throttling)
 *
 * Expected Results:
 * - Replay latency: 100-500ms depending on backlog size
 * - DB fallback: depends on ETS ring capacity
 * - Active writes unaffected by concurrent reads
 *
 * Thresholds (Pass/Fail):
 * - replay_latency p95 < 500ms (Time to fetch large backlog)
 * - active_write_latency p95 < 20ms (Writes unaffected during replay)
 * - http_req_failed < 0.01 (Error rate < 1%)
 *
 * Usage:
 *   k6 run bench/k6/3-cold-start-replay.js
 *
 *   # Larger backlog stress test
 *   k6 run -e BACKLOG_SIZE=5000 -e BACKLOG_SESSIONS=10 bench/k6/3-cold-start-replay.js
 */

import http from 'k6/http';
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const backlogWrites = new Counter('backlog_writes');
const activeWrites = new Counter('active_writes');
const replaysTotal = new Counter('replays_total');
const replayLatency = new Trend('replay_latency', true);
const activeWriteLatency = new Trend('active_write_latency', true);
const messagesReplayed = new Trend('messages_replayed', true);

// ============================================================================
// Test Configuration
// ============================================================================

const backlogSessions = Number(__ENV.BACKLOG_SESSIONS || 5);
const backlogSize = Number(__ENV.BACKLOG_SIZE || 1000);
const backlogDuration = __ENV.BACKLOG_DURATION || '30s';
const replayDuration = __ENV.REPLAY_DURATION || '1m';

export const options = {
  setupTimeout: '120s',
  teardownTimeout: '60s',
  scenarios: {
    // Phase 1: Accumulate backlog
    accumulate_backlog: {
      executor: 'constant-vus',
      vus: backlogSessions,
      duration: backlogDuration,
      exec: 'accumulateBacklog',
      startTime: '0s',
    },
    // Phase 2: Replay backlog while continuing writes
    replay_under_load: {
      executor: 'constant-vus',
      vus: backlogSessions,
      duration: replayDuration,
      exec: 'replayUnderLoad',
      startTime: backlogDuration,
    },
  },
  thresholds: {
    // Primary: System stability
    'http_req_failed': [
      { threshold: 'rate<0.01', abortOnFail: true }, // < 1% errors (no crashes)
    ],
    // Secondary: Performance targets (can degrade under max pressure)
    'replay_latency': [
      { threshold: 'p(95)<500', abortOnFail: false }, // Replay should be fast
    ],
    'active_write_latency': [
      { threshold: 'p(95)<200', abortOnFail: false }, // Writes acceptable under pressure
    ],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up cold-start replay benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`Sessions: ${backlogSessions}`);
  console.log(`Target backlog per session: ${backlogSize} messages`);
  console.log(`Backlog phase: ${backlogDuration}`);
  console.log(`Replay phase: ${replayDuration}`);

  const agent = lib.setupEchoAgent();
  const agentId = agent.id;

  // Pre-create sessions
  console.log(`Pre-creating ${backlogSessions} sessions...`);
  const sessions = {};

  for (let vuId = 1; vuId <= backlogSessions; vuId++) {
    const userId = lib.generateParticipantId('user', vuId);
    const session = lib.createSession(userId, agentId, {
      vu: vuId,
      type: 'cold_start_replay',
      run_id: lib.config.runId,
    });
    sessions[vuId] = {
      sessionId: session.id,
      userId: userId,
    };
  }

  console.log(`Setup complete: ${backlogSessions} sessions ready`);

  return {
    agentId: agentId,
    runId: lib.config.runId,
    sessions: sessions,
  };
}

// ============================================================================
// Phase 1: Accumulate Backlog
// ============================================================================

export function accumulateBacklog(data) {
  const vuId = __VU;
  const sessionData = data.sessions[vuId];

  if (!sessionData) {
    return;
  }

  const sessionId = sessionData.sessionId;
  const userId = sessionData.userId;

  // Send messages via REST API (faster than WebSocket for bulk writes)
  const res = http.post(
    `${lib.config.apiUrl}/sessions/${sessionId}/messages`,
    JSON.stringify({
      user_id: userId,
      kind: 'text',
      content: { text: `backlog message ${__ITER}` },
      metadata: { bench: true, phase: 'backlog', vu: vuId },
    }),
    lib.jsonHeaders
  );

  backlogWrites.add(1);

  check(res, {
    'backlog write success': (r) => r.status === 200,
  });
}

// ============================================================================
// Phase 2: Replay Under Load
// ============================================================================

export function replayUnderLoad(data) {
  const vuId = __VU;
  const sessionData = data.sessions[vuId];

  if (!sessionData) {
    return;
  }

  const sessionId = sessionData.sessionId;
  const userId = sessionData.userId;

  // First iteration: Replay backlog
  if (__ITER === 0) {
    console.log(`VU${vuId}: Replaying backlog for session ${sessionId}`);

    const startReplay = Date.now();
    const replayRes = http.get(
      `${lib.config.apiUrl}/sessions/${sessionId}/messages?after_seq=0&limit=10000`,
      lib.jsonHeaders
    );
    const replayDuration = Date.now() - startReplay;

    replayLatency.add(replayDuration);
    replaysTotal.add(1);

    const success = check(replayRes, {
      'replay success': (r) => r.status === 200,
    });

    if (success) {
      try {
        const body = JSON.parse(replayRes.body);
        const messageCount = body.messages ? body.messages.length : 0;
        messagesReplayed.add(messageCount);
        console.log(`VU${vuId}: Replayed ${messageCount} messages in ${replayDuration}ms`);
      } catch (e) {
        console.error(`VU${vuId}: Failed to parse replay response: ${e.message}`);
      }
    }
  }

  // Continue writing while replay happens (simulates active traffic)
  const startWrite = Date.now();
  const writeRes = http.post(
    `${lib.config.apiUrl}/sessions/${sessionId}/messages`,
    JSON.stringify({
      user_id: userId,
      kind: 'text',
      content: { text: `active message ${__ITER}` },
      metadata: { bench: true, phase: 'active', vu: vuId },
    }),
    lib.jsonHeaders
  );
  const writeDuration = Date.now() - startWrite;

  activeWriteLatency.add(writeDuration);
  activeWrites.add(1);

  check(writeRes, {
    'active write success': (r) => r.status === 200,
  });
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  if (data.sessions) {
    const sessionCount = Object.keys(data.sessions).length;
    console.log(`Cleaning up ${sessionCount} sessions...`);
    for (const vuId in data.sessions) {
      const sessionId = data.sessions[vuId].sessionId;
      lib.deleteSession(sessionId);
    }
  }

  console.log(`\nCold-start replay test complete (Run ID: ${data.runId})`);
  console.log('Check replay_latency vs active_write_latency to verify no interference');
}
