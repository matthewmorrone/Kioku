// Thin HTTP client for the Kioku bridge. Exists so MCP tool handlers stay declarative —
// they describe an operation and let the client deal with auth headers, JSON encoding,
// timeouts, and turning the bridge's structured `{ "error": { code, message } }` envelope
// into a real Error.

import type { BridgeConfig } from "./config.js";

// Returned envelope shape the Swift bridge sends for any non-2xx response.
interface BridgeErrorEnvelope {
  error: { code: string; message: string };
}

// Distinct error class so MCP tool callbacks can surface a precise message back
// to Claude rather than a generic "fetch failed".
export class BridgeRequestError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "BridgeRequestError";
    this.status = status;
    this.code = code;
  }
}

export class KiokuBridgeClient {
  private readonly config: BridgeConfig;

  constructor(config: BridgeConfig) {
    this.config = config;
  }

  // Generic JSON GET. Returns parsed body, throws BridgeRequestError on non-2xx.
  async get<T>(path: string): Promise<T> {
    return this.request<T>("GET", path);
  }

  // Generic JSON POST. Body is JSON-stringified before sending.
  async post<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>("POST", path, body);
  }

  // Generic JSON PATCH used for partial note updates.
  async patch<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>("PATCH", path, body);
  }

  // Generic JSON PUT used for segments / furigana replacements.
  async put<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>("PUT", path, body);
  }

  // DELETE returns 204 with empty body so we don't try to parse JSON afterwards.
  async delete(path: string): Promise<void> {
    await this.request<void>("DELETE", path);
  }

  // Single point of HTTP I/O. Wraps fetch with a timeout, attaches the bearer
  // token, and converts the bridge's error envelope into a typed exception.
  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.config.requestTimeoutMs);
    const url = `${this.config.baseUrl}${path}`;

    let response: Response;
    try {
      response = await fetch(url, {
        method,
        signal: controller.signal,
        headers: {
          Authorization: `Bearer ${this.config.token}`,
          ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
          Accept: "application/json",
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      throw new BridgeRequestError(0, "network_error", `request to ${url} failed: ${message}`);
    } finally {
      clearTimeout(timeout);
    }

    if (response.status === 204) {
      return undefined as T;
    }

    const text = await response.text();
    let parsed: unknown = undefined;
    if (text.length > 0) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = undefined;
      }
    }

    if (!response.ok) {
      const envelope = parsed as BridgeErrorEnvelope | undefined;
      const code = envelope?.error?.code ?? `http_${response.status}`;
      const message = envelope?.error?.message ?? (text || response.statusText);
      throw new BridgeRequestError(response.status, code, message);
    }

    return parsed as T;
  }
}
