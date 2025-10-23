'use client';

import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Socket } from "phoenix";

type ChatConfig = {
  wsUrl: string;
  agentId: string;
  userId: string;
};

type FleetMessage = {
  seq: number;
  kind: string;
  sender_id: string;
  content: any;
  metadata?: Record<string, any>;
  inserted_at: string;
};

type Session = {
  id: string;
  user_id: string;
  agent_id: string;
  inserted_at: string;
};

type StreamChunk = {
  chunk: {
    type: string;
    id?: string;
    delta?: string;
    messageId?: string;
    messageMetadata?: Record<string, any>;
  };
};

const mergeMessage = (messages: FleetMessage[], incoming: FleetMessage) => {
  const existingIndex = messages.findIndex((m) => m.seq === incoming.seq);

  if (existingIndex === -1) {
    return [...messages, incoming].sort((a, b) => a.seq - b.seq);
  }

  const next = [...messages];
  next[existingIndex] = incoming;
  return next;
};

const extractAssistantText = (message: FleetMessage) => {
  const parts = message?.content?.parts;

  if (Array.isArray(parts) && parts.length > 0) {
    return parts
      .filter((part: any) => part?.type === "text")
      .map((part: any) => part?.text ?? "")
      .join("")
      .trim();
  }

  return JSON.stringify(message.content);
};

const extractUserText = (message: FleetMessage) => {
  if (typeof message.content?.text === "string") {
    return message.content.text;
  }

  if (typeof message.content?.content?.text === "string") {
    return message.content.content.text;
  }

  return JSON.stringify(message.content);
};

const scrollToBottom = (node: HTMLDivElement | null) => {
  if (!node) return;
  node.scrollTop = node.scrollHeight;
};

export function ChatApp({ config }: { config: ChatConfig }) {
  const [session, setSession] = useState<Session | null>(null);
  const [messages, setMessages] = useState<FleetMessage[]>([]);
  const [liveAssistant, setLiveAssistant] = useState<string | null>(null);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const messageListRef = useRef<HTMLDivElement | null>(null);
  const socketRef = useRef<Socket | null>(null);

  const sessionLabel = useMemo(() => {
    if (!session) return "loading…";
    return `${session.id.slice(0, 4)}…${session.id.slice(-4)}`;
  }, [session]);

  useEffect(() => {
    const bootstrap = async () => {
      try {
        setLoading(true);

        const response = await fetch("/api/fleetlm/session", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            userId: config.userId,
            agentId: config.agentId
          })
        });

        if (!response.ok) {
          throw new Error(`HTTP ${response.status} ${await response.text()}`);
        }

        const { session: created } = await response.json();
        setSession(created);
        setMessages([]);
        setError(null);
      } catch (err) {
        console.error(err);
        setError(`Failed to initialise session: ${String(err)}`);
      } finally {
        setLoading(false);
      }
    };

    bootstrap();
  }, [config.agentId, config.userId]);

  useEffect(() => {
    if (!session) return;

    const socket = new Socket(config.wsUrl, {
      params: { user_id: config.userId }
    });

    socket.connect();
    socketRef.current = socket;

    const channel = socket.channel(`session:${session.id}`, {});

    channel
      .join()
      .receive("ok", (resp: { messages?: FleetMessage[] }) => {
        const initial = (resp.messages ?? []).sort((a, b) => a.seq - b.seq);
        setMessages(initial);
        setError(null);
      })
      .receive("error", (resp: any) => {
        console.error("join failed", resp);
        setError("Failed to join session channel");
      });

    channel.on("message", (payload: FleetMessage) => {
      setMessages((prev) => mergeMessage(prev, payload));

      if (payload.kind === "assistant") {
        setLiveAssistant(null);
      }
    });

    channel.on("stream_chunk", (payload: StreamChunk) => {
      const chunk = payload.chunk;

      switch (chunk.type) {
        case "start":
        case "text-start":
          setLiveAssistant("");
          break;
        case "text-delta":
          setLiveAssistant((prev) => (prev ?? "") + (chunk.delta ?? ""));
          break;
        case "text-end":
          // wait for finish -> persisted message
          break;
        case "finish":
        case "abort":
          setLiveAssistant(null);
          break;
        default:
          break;
      }
    });

    return () => {
      channel.leave();
      socket.disconnect();
      socketRef.current = null;
      setLiveAssistant(null);
    };
  }, [config.userId, config.wsUrl, session]);

  useEffect(() => {
    scrollToBottom(messageListRef.current);
  }, [messages, liveAssistant]);

  const handleSubmit = useCallback(
    async (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();

      if (!session || sending) return;
      const text = input.trim();

      if (!text) {
        return;
      }

      try {
        setSending(true);
        setError(null);

        const response = await fetch("/api/fleetlm/send", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            sessionId: session.id,
            userId: config.userId,
            text
          })
        });

        if (!response.ok) {
          throw new Error(`HTTP ${response.status} ${await response.text()}`);
        }

        setInput("");
      } catch (err) {
        console.error(err);
        setError(`Failed to send message: ${String(err)}`);
      } finally {
        setSending(false);
      }
    },
    [config.userId, input, sending, session]
  );

  return (
    <>
      <div className="chat-shell">
        <header className="chat-header">
          <div>
            <p className="eyebrow">FleetLM × Next.js</p>
            <h1>Demo chat</h1>
          </div>
          <div className="session-pill">
            <span>session</span>
            <strong>{sessionLabel}</strong>
          </div>
        </header>

        <section className="chat-body" ref={messageListRef}>
          {loading && <p className="system">Connecting to FleetLM…</p>}
          {error && <p className="system error">{error}</p>}

          {!loading &&
            messages.map((message) => (
              <article
                key={message.seq}
                className={message.sender_id === config.userId ? "bubble user" : "bubble agent"}
              >
                <span className="sender">
                  {message.sender_id === config.userId ? "You" : "Agent"}
                </span>
                <p>
                  {message.kind === "assistant"
                    ? extractAssistantText(message)
                    : extractUserText(message)}
                </p>
                <time>{new Date(message.inserted_at).toLocaleTimeString()}</time>
              </article>
            ))}

          {liveAssistant !== null && (
            <article className="bubble agent streaming">
              <span className="sender">Agent (streaming)</span>
              <p>{liveAssistant || "…"}</p>
              <time>live</time>
            </article>
          )}
        </section>

        <form className="composer" onSubmit={handleSubmit}>
          <input
            type="text"
            placeholder="Ask something…"
            value={input}
            onChange={(event) => setInput(event.target.value)}
            disabled={!session || sending}
          />
          <button type="submit" disabled={!session || sending || !input.trim()}>
            {sending ? "Sending…" : "Send"}
          </button>
        </form>

        <footer className="chat-footer">
          <p>
            Update <code>app/api/fleetlm/webhook/route.ts</code> to call your real LLM. FleetLM
            handles ordering, retries, and streaming.
          </p>
        </footer>
      </div>

      <style jsx>{`
        .chat-shell {
          display: grid;
          gap: 1.25rem;
          background: rgba(15, 23, 42, 0.65);
          border: 1px solid rgba(148, 163, 184, 0.1);
          border-radius: 24px;
          padding: 2rem;
          box-shadow: 0 20px 60px rgba(15, 23, 42, 0.45);
        }

        .chat-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          gap: 1rem;
        }

        .chat-header h1 {
          margin: 0.25rem 0 0;
          font-size: 1.75rem;
        }

        .eyebrow {
          margin: 0;
          text-transform: uppercase;
          font-size: 0.75rem;
          letter-spacing: 0.08em;
          color: rgba(148, 163, 184, 0.8);
        }

        .session-pill {
          display: flex;
          align-items: center;
          gap: 0.5rem;
          background: rgba(59, 130, 246, 0.2);
          border: 1px solid rgba(37, 99, 235, 0.35);
          border-radius: 999px;
          padding: 0.5rem 0.9rem;
          font-size: 0.85rem;
          color: #dbeafe;
        }

        .session-pill span {
          opacity: 0.7;
        }

        .chat-body {
          min-height: 360px;
          max-height: 480px;
          overflow-y: auto;
          display: flex;
          flex-direction: column;
          gap: 0.75rem;
          padding-right: 0.25rem;
        }

        .system {
          margin: 0;
          color: rgba(148, 163, 184, 0.8);
          font-size: 0.9rem;
        }

        .system.error {
          color: rgb(248, 113, 113);
        }

        .bubble {
          display: inline-flex;
          flex-direction: column;
          gap: 0.5rem;
          max-width: 78%;
          padding: 0.9rem 1rem;
          border-radius: 18px;
          position: relative;
        }

        .bubble.user {
          margin-left: auto;
          background: linear-gradient(135deg, rgba(59, 130, 246, 0.75), rgba(37, 99, 235, 0.6));
          color: #eff6ff;
        }

        .bubble.agent {
          margin-right: auto;
          background: rgba(30, 41, 59, 0.7);
          color: #f8fafc;
          border: 1px solid rgba(148, 163, 184, 0.15);
        }

        .bubble.streaming {
          animation: pulse 1.8s ease-in-out infinite;
        }

        .bubble p {
          margin: 0;
          white-space: pre-wrap;
          line-height: 1.5;
        }

        .bubble time {
          font-size: 0.7rem;
          opacity: 0.6;
        }

        .sender {
          font-size: 0.75rem;
          text-transform: uppercase;
          letter-spacing: 0.08em;
          opacity: 0.7;
        }

        .composer {
          display: flex;
          gap: 0.75rem;
          align-items: center;
        }

        .composer input {
          flex: 1;
          padding: 0.85rem 1rem;
          border-radius: 16px;
          border: 1px solid rgba(148, 163, 184, 0.2);
          background: rgba(15, 23, 42, 0.55);
          color: #f8fafc;
          font-size: 1rem;
        }

        .composer input::placeholder {
          color: rgba(148, 163, 184, 0.7);
        }

        .composer button {
          padding: 0.85rem 1.4rem;
          border-radius: 16px;
          border: none;
          background: linear-gradient(135deg, rgba(56, 189, 248, 0.95), rgba(37, 99, 235, 0.95));
          color: #0f172a;
          font-weight: 600;
          cursor: pointer;
          transition: transform 120ms ease, box-shadow 120ms ease;
        }

        .composer button:disabled {
          opacity: 0.6;
          cursor: not-allowed;
          transform: none;
          box-shadow: none;
        }

        .composer button:not(:disabled):hover {
          transform: translateY(-1px);
          box-shadow: 0 10px 25px rgba(37, 99, 235, 0.25);
        }

        .chat-footer {
          font-size: 0.85rem;
          color: rgba(148, 163, 184, 0.85);
          margin: 0;
        }

        code {
          background: rgba(15, 23, 42, 0.65);
          padding: 0.15rem 0.35rem;
          border-radius: 6px;
          font-size: 0.85rem;
        }

        @keyframes pulse {
          0% {
            box-shadow: 0 0 0 0 rgba(59, 130, 246, 0.35);
          }
          70% {
            box-shadow: 0 0 0 12px rgba(59, 130, 246, 0);
          }
          100% {
            box-shadow: 0 0 0 0 rgba(59, 130, 246, 0);
          }
        }

        @media (max-width: 640px) {
          .chat-shell {
            padding: 1.5rem;
          }

          .bubble {
            max-width: 92%;
          }
        }
      `}</style>
    </>
  );
}
