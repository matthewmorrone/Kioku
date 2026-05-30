// Loads bridge connection settings from environment variables. Kept tiny on purpose —
// the MCP server has no other configuration beyond "where is Kioku and what's the token".

export interface BridgeConfig {
  baseUrl: string;
  token: string;
  requestTimeoutMs: number;
}

// Reads required env vars and validates them at startup so misconfiguration fails
// loudly with one message rather than per-tool when the user invokes a tool.
export function loadConfig(): BridgeConfig {
  const baseUrl = process.env.KIOKU_BRIDGE_URL?.trim();
  const token = process.env.KIOKU_BRIDGE_TOKEN?.trim();

  if (!baseUrl) {
    throw new Error("KIOKU_BRIDGE_URL is not set. Example: KIOKU_BRIDGE_URL=http://192.168.1.42:47823");
  }
  if (!token) {
    throw new Error("KIOKU_BRIDGE_TOKEN is not set. Copy it from Kioku → Settings → MCP Bridge.");
  }

  let parsed: URL;
  try {
    parsed = new URL(baseUrl);
  } catch {
    throw new Error(`KIOKU_BRIDGE_URL is not a valid URL: ${baseUrl}`);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error(`KIOKU_BRIDGE_URL must use http or https, got ${parsed.protocol}`);
  }

  const timeoutRaw = process.env.KIOKU_BRIDGE_TIMEOUT_MS?.trim();
  const requestTimeoutMs = timeoutRaw ? Number.parseInt(timeoutRaw, 10) : 10_000;
  if (!Number.isFinite(requestTimeoutMs) || requestTimeoutMs <= 0) {
    throw new Error(`KIOKU_BRIDGE_TIMEOUT_MS must be a positive integer, got ${timeoutRaw}`);
  }

  return {
    baseUrl: baseUrl.replace(/\/+$/, ""),
    token,
    requestTimeoutMs,
  };
}
