/**
 * Fastpaca k6 Benchmark Library
 *
 * Helpers for exercising the Fastpaca context API during load tests.
 */

import http from 'k6/http';
import { check } from 'k6';

// ============================================================================
// Configuration
// ============================================================================

// Support load balancing across multiple cluster nodes
const clusterNodes = __ENV.CLUSTER_NODES
  ? __ENV.CLUSTER_NODES.split(',').map(url => url.trim().replace(/\/$/, ''))
  : [(__ENV.API_URL || 'http://localhost:4000/v1').replace(/\/$/, '')];

let nodeIndex = 0;

function getNextNode() {
  const node = clusterNodes[nodeIndex % clusterNodes.length];
  nodeIndex++;
  return node;
}

export const config = {
  apiUrl: clusterNodes[0], // Default for backward compatibility
  getNextNode: getNextNode,
  clusterNodes: clusterNodes,
  runId: __ENV.RUN_ID || `${Date.now()}-${Math.floor(Math.random() * 10000)}`,
  defaultTokenBudget: Number(__ENV.TOKEN_BUDGET || 1_000_000),
  defaultTriggerRatio: Number(__ENV.TRIGGER_RATIO || 0.7),
};

export const jsonHeaders = {
  headers: {
    'Content-Type': 'application/json',
  },
};

const defaultPolicy = (() => {
  if (__ENV.CONTEXT_POLICY) {
    try {
      return JSON.parse(__ENV.CONTEXT_POLICY);
    } catch (err) {
      console.warn(`Failed to parse CONTEXT_POLICY env var, falling back to last_n: ${err}`);
    }
  }
  return { strategy: 'last_n', config: { limit: 400 } };
})();

// ============================================================================
// Context helpers
// ============================================================================

function buildUrl(path, params = {}, useLoadBalancer = true) {
  const query = Object.entries(params)
    .filter(([, value]) => value !== undefined && value !== null && value !== '')
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join('&');

  // Use load balancer if enabled and multiple nodes available
  const baseUrl = (useLoadBalancer && clusterNodes.length > 1) ? getNextNode() : config.apiUrl;

  return query ? `${baseUrl}${path}?${query}` : `${baseUrl}${path}`;
}

export function waitForClusterReady(timeoutSeconds = 60) {
  const startTime = Date.now();
  const timeoutMs = timeoutSeconds * 1000;

  console.log(`Waiting for ${clusterNodes.length} node(s) to be ready...`);

  while (Date.now() - startTime < timeoutMs) {
    let allReady = true;

    for (const node of clusterNodes) {
      const res = http.get(`${node.replace('/v1', '')}/health/ready`, { timeout: '5s' });
      if (res.status !== 200) {
        allReady = false;
        break;
      }
    }

    if (allReady) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      console.log(`✓ All ${clusterNodes.length} node(s) ready after ${elapsed}s`);
      return true;
    }

    // Wait 1s before retry
    http.get('https://httpbin.test.k6.io/delay/1');
  }

  throw new Error(`Cluster did not become ready within ${timeoutSeconds}s`);
}

export function contextId(prefix, vuId, extra = '') {
  const suffix = extra ? `-${extra}` : '';
  return `${prefix}-${vuId}${suffix}`;
}

export function randomId(prefix) {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return `${prefix}-${crypto.randomUUID()}`;
  }
  const rand = Math.floor(Math.random() * 1_000_000_000);
  return `${prefix}-${Date.now()}-${rand}`;
}

export function ensureContext(id, overrides = {}) {
  const payload = {
    token_budget: overrides.token_budget ?? config.defaultTokenBudget,
    trigger_ratio: overrides.trigger_ratio ?? config.defaultTriggerRatio,
    policy: overrides.policy ?? defaultPolicy,
  };

  if (overrides.metadata) {
    payload.metadata = overrides.metadata;
  }

  const res = http.put(
    buildUrl(`/contexts/${id}`),
    JSON.stringify(payload),
    jsonHeaders
  );

  check(res, {
    [`ensure context ${id}`]: (r) => r.status === 200 || r.status === 201,
  });

  if (res.status >= 400) {
    throw new Error(`Failed to ensure context ${id}: ${res.status} ${res.body}`);
  }

  try {
    return JSON.parse(res.body);
  } catch (_err) {
    return null;
  }
}

export function appendMessage(contextId, message, opts = {}) {
  const payload = {
    message,
  };

  if (opts.ifVersion !== undefined && opts.ifVersion !== null) {
    payload.if_version = opts.ifVersion;
  }

  const res = http.post(
    buildUrl(`/contexts/${contextId}/messages`),
    JSON.stringify(payload),
    jsonHeaders
  );

  return {
    res,
    json: safeParse(res.body),
  };
}

export function getContextWindow(contextId, params = {}) {
  const res = http.get(
    buildUrl(`/contexts/${contextId}/context`, params),
    jsonHeaders
  );

  return {
    res,
    json: safeParse(res.body),
  };
}

export function getMessages(contextId, params = {}) {
  const res = http.get(
    buildUrl(`/contexts/${contextId}/messages`, params),
    jsonHeaders
  );

  return {
    res,
    json: safeParse(res.body),
  };
}

export function compactContext(contextId, payload) {
  const res = http.post(
    buildUrl(`/contexts/${contextId}/compact`),
    JSON.stringify(payload),
    jsonHeaders
  );

  return {
    res,
    json: safeParse(res.body),
  };
}

export function deleteContext(contextId) {
  return http.del(buildUrl(`/contexts/${contextId}`), null, jsonHeaders);
}

function safeParse(body) {
  try {
    return JSON.parse(body);
  } catch (_err) {
    return null;
  }
}
