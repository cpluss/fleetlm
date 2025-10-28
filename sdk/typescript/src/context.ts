import type { UIMessage } from 'ai';
import type { ContextWindow, AppendResponse } from './types';


/**
 * Context class - represents a single context
 */
export class Context {
  constructor(
    private contextId: string,
    private baseUrl: string,
    private apiKey?: string
  ) {}

  /**
   * Append a message to the context
   *
   * @param message - UIMessage from AI SDK
   * @param opts - Optional parameters including token count override and version guard
   */
  async append(
    message: UIMessage,
    opts?: { ifVersion?: number; tokenCount?: number }
  ): Promise<AppendResponse> {

    const response = await fetch(`${this.baseUrl}/contexts/${this.contextId}/messages`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(this.apiKey && { Authorization: `Bearer ${this.apiKey}` }),
      },
      body: JSON.stringify({
        message: {
          role: message.role,
          parts: message.parts,
          ...(typeof opts?.tokenCount === 'number' ? { token_count: opts!.tokenCount } : {}),
        },
        if_version: opts?.ifVersion,
      }),
    });

    if (!response.ok) {
      throw new Error(`Failed to append message: ${response.statusText}`);
    }

    return response.json();
  }

  /**
   * Get the context window (pre-computed, for LLM)
   */
  async context(opts?: { ifVersion?: number; budgetTokens?: number }): Promise<ContextWindow> {
    const params = new URLSearchParams();
    if (opts?.ifVersion) {
      params.set('if_version', opts.ifVersion.toString());
    }
    if (opts?.budgetTokens) {
      params.set('budget_tokens', opts.budgetTokens.toString());
    }

    const url = `${this.baseUrl}/contexts/${this.contextId}/context${params.toString() ? `?${params}` : ''}`;
    const response = await fetch(url, {
      headers: {
        ...(this.apiKey && { Authorization: `Bearer ${this.apiKey}` }),
      },
    });

    if (!response.ok) {
      throw new Error(`Failed to fetch context: ${response.statusText}`);
    }

    return response.json();
  }

  /**
   * Stream a response using ai-sdk
   *
   * @param fn - Function that receives messages and returns an ai-sdk stream result
   * @returns Response object suitable for returning from API routes
   *
   * @example
   * ```ts
   * return ctx.stream(async (messages) => {
   *   return streamText({
   *     model: openai('gpt-4o-mini'),
   *     messages: convertToModelMessages(messages)
   *   });
   * });
   * ```
   */
  async stream(
    fn: (messages: UIMessage[]) => Promise<{ toDataStreamResponse: () => Response }>
  ): Promise<Response> {
    const window = await this.context();
    const streamResult = await fn(window.messages);
    if (!streamResult || typeof streamResult.toDataStreamResponse !== 'function') {
      throw new Error('ctx.stream expects an ai-sdk v4 stream result with toDataStreamResponse()');
    }
    return streamResult.toDataStreamResponse();
  }

  /**
   * Manual compaction
   */
  async compact(
    replacement: UIMessage[],
    opts?: { ifVersion?: number }
  ): Promise<{ version: number }> {
    const response = await fetch(`${this.baseUrl}/contexts/${this.contextId}/compact`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(this.apiKey && { Authorization: `Bearer ${this.apiKey}` }),
      },
      body: JSON.stringify({
        replacement,
        if_version: opts?.ifVersion,
      }),
    });

    if (!response.ok) {
      throw new Error(`Failed to compact: ${response.statusText}`);
    }

    return response.json();
  }

  /**
   * Get messages (for replay/list)
   */
  async getTail(opts?: { offset?: number; limit?: number }): Promise<{ messages: UIMessage[] }> {
    const params = new URLSearchParams();
    if (typeof opts?.offset === 'number') params.set('offset', String(opts.offset));
    if (typeof opts?.limit === 'number') params.set('limit', String(opts.limit));

    const url = `${this.baseUrl}/contexts/${this.contextId}/tail${params.toString() ? `?${params}` : ''}`;
    const response = await fetch(url, {
      headers: {
        ...(this.apiKey && { Authorization: `Bearer ${this.apiKey}` }),
      },
    });

    if (!response.ok) {
      throw new Error(`Failed to fetch tail: ${response.statusText}`);
    }

    return response.json();
  }
}
