/**
 * Fastpaca Scenario 4: Durability Cadence
 *
 * Sustained append workload that periodically inspects the context window to
 * ensure compaction signals surface without losing history.
 *
 * Profile:
 * - sessionCount contexts (default 10)
 * - Constant VUs for configurable duration (default 3m)
 * - Every 10th iteration fetches the LLM window to observe needs_compaction
 *
 * Thresholds (Pass/Fail):
 * - append_latency p99 < 200ms
 * - http_req_failed < 1%
 * - durability_check == 1 (tail replay matches appended count)
 *
 * Usage:
 *   k6 run bench/k6/4-durability-cadence.js
 *
 *   # Longer soak
 *   k6 run -e DURATION=15m bench/k6/4-durability-cadence.js
 */

import { check } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';
import * as lib from './lib.js';

// ============================================================================
// Metrics
// ============================================================================

const messagesSent = new Counter('messages_sent');
const appendLatency = new Trend('append_latency', true);
const windowLatency = new Trend('window_latency', true);
const needsCompactionTrips = new Counter('needs_compaction_trips');
const durabilityCheck = new Rate('durability_check');

// ============================================================================
// Test Configuration
// ============================================================================

const sessionCount = Number(__ENV.SESSION_COUNT || 10);
const duration = __ENV.DURATION || '3m';
const verifyTailLimit = Number(__ENV.VERIFY_TAIL_LIMIT || 2000);

export const options = {
  setupTimeout: '120s',
  teardownTimeout: '120s',
  scenarios: {
    sustained_load: {
      executor: 'constant-vus',
      vus: sessionCount,
      duration,
    },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true }],
    append_latency: [
      { threshold: 'p(95)<120', abortOnFail: false },
      { threshold: 'p(99)<200', abortOnFail: false },
    ],
    durability_check: [{ threshold: 'rate==1', abortOnFail: true }],
  },
};

// ============================================================================
// Setup
// ============================================================================

export function setup() {
  console.log('Setting up durability cadence benchmark...');
  console.log(`Run ID: ${lib.config.runId}`);
  console.log(`Contexts: ${sessionCount}`);
  console.log(`Duration: ${duration}`);

  const contexts = {};

  for (let vuId = 1; vuId <= sessionCount; vuId++) {
    const contextId = lib.contextId('durability', vuId);
    lib.ensureContext(contextId, {
      metadata: {
        bench: true,
        scenario: 'durability_cadence',
        vu: vuId,
        run_id: lib.config.runId,
      },
    });
    contexts[vuId] = { contextId, appended: 0, lastSeq: 0, version: 0 };
  }

  return {
    runId: lib.config.runId,
    contexts,
    verifyTailLimit,
  };
}

// ============================================================================
// Main Test
// ============================================================================

export default function (data) {
  const vuId = __VU;
  const ctx = data.contexts[vuId];
  if (!ctx) {
    return;
  }

  const messageSeq = ctx.appended + 1;
  const messageText = `durability message run=${data.runId} vu=${vuId} seq=${messageSeq}`;

  const { res, json } = lib.appendMessage(
    ctx.contextId,
    {
      role: 'assistant',
      parts: [{ type: 'text', text: messageText }],
      metadata: {
        bench: true,
        scenario: 'durability_cadence',
        vu: vuId,
        seq: messageSeq,
        iter: __ITER,
      },
    }
  );

  appendLatency.add(res.timings.duration);
  messagesSent.add(1);

  const ok = check(res, {
    'append ok': (r) => r.status >= 200 && r.status < 300,
  });

  if (!ok) {
    console.error(`VU${vuId}: append failed status=${res.status} body=${res.body}`);
    return;
  }

  ctx.appended = messageSeq;

  if (json) {
    if (typeof json.seq === 'number') {
      ctx.lastSeq = json.seq;
    }
    if (typeof json.version === 'number') {
      ctx.version = json.version;
    }
  }

  // Every 10th iteration, fetch the LLM window to check compaction signals.
  if (ctx.appended % 10 === 0) {
    const { res: windowRes, json: windowJson } = lib.getContextWindow(ctx.contextId);
    windowLatency.add(windowRes.timings.duration);

    check(windowRes, {
      'window fetch ok': (r) => r.status === 200,
    });

    if (windowJson && windowJson.needs_compaction === true) {
      needsCompactionTrips.add(1);
    }
  }
}

// ============================================================================
// Teardown
// ============================================================================

export function teardown(data) {
  console.log('Verifying durability tail across contexts...');

  Object.values(data.contexts).forEach((ctx) => {
    if (!ctx || ctx.appended === 0) {
      durabilityCheck.add(true);
      return;
    }

    const limit = Math.min(ctx.appended, data.verifyTailLimit);
    const { res, json } = lib.getMessages(ctx.contextId, {
      from_seq: -limit,
      limit,
    });

    const ok = res.status === 200 && json && Array.isArray(json.messages);
    if (!ok) {
      console.error(
        `Durability check failed context=${ctx.contextId} status=${res.status} body=${res.body}`
      );
      durabilityCheck.add(false);
      return;
    }

    const tailLength = json.messages.length;
    const lastMessage = tailLength > 0 ? json.messages[tailLength - 1] : null;
    const seqMatches = lastMessage ? lastMessage.seq === ctx.lastSeq : ctx.lastSeq === 0;

    durabilityCheck.add(seqMatches);

    if (!seqMatches) {
      console.error(
        `Seq mismatch context=${ctx.contextId} expected=${ctx.lastSeq} got=${lastMessage ? lastMessage.seq : 'none'}`
      );
    }
  });
}
