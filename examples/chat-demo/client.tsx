#!/usr/bin/env node
import React, { useState, useEffect } from "react";
import { render, Box, Text, useInput, useApp } from "ink";
import TextInput from "ink-text-input";
import { Socket } from "phoenix";

const API_URL = process.env.API_URL || "http://localhost:4000";
const WS_URL = process.env.WS_URL || "ws://localhost:4000/socket";
const USER_ID = process.env.USER_ID || process.env.PARTICIPANT_ID || "chat-demo-client";
const AGENT_ID = process.env.AGENT_ID || "demo-agent";

interface Message {
  seq: number;
  sender_id: string;
  kind: string;
  content: any;
  inserted_at: string;
}

interface Session {
  id: string;
  user_id: string;
  agent_id: string;
  inserted_at: string;
}

type View = "loading" | "session-list" | "chat";

const App = () => {
  const [view, setView] = useState<View>("loading");
  const [sessions, setSessions] = useState<Session[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [currentSession, setCurrentSession] = useState<Session | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [inputValue, setInputValue] = useState("");
  const [channel, setChannel] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);
  const { exit } = useApp();

  useEffect(() => {
    loadSessions();
  }, []);

  const loadSessions = async () => {
    try {
      const response = await fetch(
        `${API_URL}/api/sessions?user_id=${USER_ID}`
      );

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = await response.json();
      const sessionList = data.sessions || [];

      if (sessionList.length === 0) {
        createNewSession();
      } else {
        setSessions(sessionList);
        setView("session-list");
      }
    } catch (err) {
      setError(`Failed to load sessions: ${err}`);
      createNewSession();
    }
  };

  const createNewSession = async () => {
    try {
      const response = await fetch(`${API_URL}/api/sessions`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sender_id: USER_ID,
          recipient_id: AGENT_ID,
          metadata: {},
        }),
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = await response.json();
      const session = data.session;
      joinSession(session);
    } catch (err) {
      setError(`Failed to create session: ${err}`);
      setView("chat");
    }
  };

  const joinSession = (session: Session) => {
    setCurrentSession(session);
    setMessages([]);
    setView("chat");

    const socket = new Socket(WS_URL, {
      params: { user_id: USER_ID },
    });

    socket.connect();

    const ch = socket.channel(`session:${session.id}`, {});

    ch.join()
      .receive("ok", (resp: any) => {
        setMessages(resp.messages || []);
      })
      .receive("error", (resp: any) => {
        setError(`Failed to join: ${resp.reason || "unknown"}`);
      });

    ch.on("message", (payload: Message) => {
      setMessages((prev) => [...prev, payload]);
    });

    setChannel(ch);
  };

  const sendMessage = () => {
    if (!inputValue.trim() || !channel) return;

    channel
      .push("send", {
        content: {
          kind: "text",
          content: { text: inputValue },
        },
      })
      .receive("error", (err: any) => {
        setError(`Send failed: ${err.error || "unknown"}`);
      });

    setInputValue("");
  };

  useInput((input, key) => {
    if (view === "session-list") {
      if (key.upArrow && selectedIndex > 0) {
        setSelectedIndex(selectedIndex - 1);
      } else if (key.downArrow && selectedIndex < sessions.length) {
        setSelectedIndex(selectedIndex + 1);
      } else if (key.return) {
        if (selectedIndex === sessions.length) {
          createNewSession();
        } else {
          joinSession(sessions[selectedIndex]);
        }
      }
    }

    if (input === "q" || (key.ctrl && input === "c")) {
      exit();
    }
  });

  if (view === "loading") {
    return <Text>Loading...</Text>;
  }

  if (view === "session-list") {
    return (
      <Box flexDirection="column">
        <Text>Select Session</Text>
        <Text>User: {USER_ID} | Agent: {AGENT_ID}</Text>
        <Text> </Text>

        {error && <Text color="red">{error}</Text>}

        {sessions.map((session, index) => (
          <Text key={session.id}>
            {selectedIndex === index ? "> " : "  "}
            {session.id} - {new Date(session.inserted_at).toLocaleString()}
          </Text>
        ))}

        <Text>
          {selectedIndex === sessions.length ? "> " : "  "}
          Create New Session
        </Text>

        <Text> </Text>
        <Text>up/down | enter | q: quit</Text>
      </Box>
    );
  }

  if (view === "chat") {
    return (
      <Box flexDirection="column">
        <Text>Session: {currentSession?.id}</Text>
        <Text> </Text>

        {error && <Text color="red">{error}</Text>}

        {messages.length === 0 ? (
          <Text>No messages</Text>
        ) : (
          messages.map((msg, index) => {
            const isUser = msg.sender_id === USER_ID;
            const content =
              typeof msg.content === "object" && msg.content.text
                ? msg.content.text
                : JSON.stringify(msg.content);

            return (
              <Text key={index}>
                {isUser ? "You" : "Agent"}: {content}
              </Text>
            );
          })
        )}

        <Text> </Text>
        <Box>
          <Text>Message: </Text>
          <TextInput
            value={inputValue}
            onChange={setInputValue}
            onSubmit={sendMessage}
          />
        </Box>
      </Box>
    );
  }

  return null;
};

render(<App />);
