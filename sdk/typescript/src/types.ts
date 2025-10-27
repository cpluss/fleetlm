import type { UIMessage } from 'ai';

/**
 * Re-export UIMessage from AI SDK
 */
export type { UIMessage };

/**
 * Context policy
 */
export interface ContextPolicy {
  strategy: 'last_n' | 'skip_parts' | 'manual';
  config: Record<string, any>;
}

/**
 * Context configuration
 */
export interface ContextConfig {
  id: string;
  token_budget: number;
  trigger_ratio?: number;
  policy: ContextPolicy;
  metadata?: Record<string, any>;
}

/**
 * Context window response
 */
export interface ContextWindow {
  version: number;
  messages: UIMessage[];
  used_tokens: number;
  needs_compaction: boolean;
  segments?: Array<{
    type: 'summary' | 'live';
    from_seq: number;
    to_seq: number;
  }>;
}

/**
 * Append response
 */
export interface AppendResponse {
  seq: number;
  version: number;
  token_estimate: number;
}

/**
 * Client configuration
 */
export interface FastpacaClientConfig {
  baseUrl?: string;
  apiKey?: string;
}
