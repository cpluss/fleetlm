type FleetSession = {
  id: string;
  user_id: string;
  agent_id: string;
  metadata?: Record<string, any>;
  inserted_at: string;
};

type FleetMessage = {
  seq: number;
  kind: string;
  sender_id: string;
  content: any;
  metadata?: Record<string, any>;
  inserted_at: string;
};

const API_URL = process.env.FLEETLM_API_URL ?? "http://localhost:4000";

const jsonHeaders = {
  Accept: "application/json",
  "Content-Type": "application/json"
};

async function jsonFetch(
  path: string,
  init: RequestInit & { body?: string } = {}
): Promise<any> {
  const response = await fetch(`${API_URL}${path}`, {
    ...init,
    headers: {
      ...jsonHeaders,
      ...(init.headers ?? {})
    }
  });

  if (!response.ok) {
    const detail = await safeText(response);
    throw new Error(`FleetLM ${response.status}: ${detail}`);
  }

  const contentType = response.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    return response.json();
  }

  return response.text();
}

async function safeText(response: Response) {
  try {
    return await response.text();
  } catch (_err) {
    return "unknown error";
  }
}

export async function createSession(userId: string, agentId: string) {
  const payload = {
    user_id: userId,
    agent_id: agentId,
    metadata: { source: "nextjs-demo" }
  };

  const body = JSON.stringify(payload);
  const { session } = await jsonFetch("/api/sessions", { method: "POST", body });
  return session as FleetSession;
}

export async function listSessions(userId: string) {
  const query = new URLSearchParams({ user_id: userId });
  const data = await jsonFetch(`/api/sessions?${query.toString()}`);
  return (data.sessions ?? []) as FleetSession[];
}

export async function sendUserMessage(sessionId: string, userId: string, text: string) {
  const payload = {
    user_id: userId,
    kind: "text",
    content: { text }
  };

  const body = JSON.stringify(payload);
  const data = await jsonFetch(`/api/sessions/${sessionId}/messages`, {
    method: "POST",
    body
  });

  return data.message as FleetMessage;
}
