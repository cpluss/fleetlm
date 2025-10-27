import { Context } from './context';
import type { FastpacaClientConfig, ContextConfig, ContextPolicy } from './types';

/**
 * Fastpaca client
 */
export class FastpacaClient {
  private baseUrl: string;
  private apiKey?: string;

  constructor(config: FastpacaClientConfig = {}) {
    this.baseUrl = config.baseUrl || 'http://localhost:4000/v1';
    this.apiKey = config.apiKey;
  }

  /**
   * Get or create a context
   *
   * If options are provided, calls PUT /v1/contexts/:id (idempotent create/update).
   * Otherwise returns a Context instance immediately.
   *
   * @example
   * ```ts
   * // Create/update context with config
   * const ctx = await fastpaca.context('chat-123', {
   *   budget: 400_000,
   *   trigger: 0.7,
   *   policy: { strategy: 'last_n', config: { limit: 400 } }
   * });
   *
   * // Get existing context (no server call)
   * const ctx = fastpaca.context('chat-123');
   * ```
   */
  async context(
    id: string,
    opts?: {
      budget?: number;
      trigger?: number;
      policy?: ContextPolicy;
      metadata?: Record<string, any>;
    }
  ): Promise<Context> {
    // If options provided, create/update the context
    if (opts) {
      const response = await fetch(`${this.baseUrl}/contexts/${id}`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          ...(this.apiKey && { Authorization: `Bearer ${this.apiKey}` }),
        },
        body: JSON.stringify({
          token_budget: opts.budget,
          trigger_ratio: opts.trigger,
          policy: opts.policy,
          metadata: opts.metadata,
        }),
      });

      if (!response.ok) {
        throw new Error(`Failed to create/update context: ${response.statusText}`);
      }
    }

    return new Context(id, this.baseUrl, this.apiKey);
  }

  /**
   * Delete a context
   */
  async deleteContext(id: string): Promise<void> {
    const response = await fetch(`${this.baseUrl}/contexts/${id}`, {
      method: 'DELETE',
      headers: {
        ...(this.apiKey && { Authorization: `Bearer ${this.apiKey}` }),
      },
    });

    if (!response.ok) {
      throw new Error(`Failed to delete context: ${response.statusText}`);
    }
  }
}

/**
 * Create a Fastpaca client
 */
export function createClient(config?: FastpacaClientConfig): FastpacaClient {
  return new FastpacaClient(config);
}
