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

const trimmedApiUrl = (__ENV.API_URL || 'http://localhost:4000/v1').replace(/\/$/, '');

export const config = {
  apiUrl: trimmedApiUrl,
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

function buildUrl(path, params = {}) {
  const query = Object.entries(params)
    .filter(([, value]) => value !== undefined && value !== null && value !== '')
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join('&');

  return query ? `${config.apiUrl}${path}?${query}` : `${config.apiUrl}${path}`;
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
