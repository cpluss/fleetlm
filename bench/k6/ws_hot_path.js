import http from 'k6/http';
import ws from 'k6/ws';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const appendLatency = new Trend('append_latency_ms', true);
const joinLatency = new Trend('join_latency_ms', true);
const messageFailures = new Counter('append_failures');

const API_BASE = __ENV.API_URL || 'http://localhost:4000/api';
const JSON_HEADERS = {
  headers: {
    'Content-Type': 'application/json',
  },
};

export const options = {
  vus: Number(__ENV.VUS || 50),
  duration: __ENV.DURATION || '1m',
  setupTimeout: __ENV.SETUP_TIMEOUT || '30s',
  thresholds: {
    append_latency_ms: ['p(95)<150'],
  },
};

export function setup() {
  const suffix = `${Date.now()}-${Math.floor(Math.random() * 1000)}`;
  const userId = __ENV.BENCH_USER_ID || `bench-user-${suffix}`;
  const agentId = __ENV.BENCH_AGENT_ID || `bench-agent-${suffix}`;
  const userName = __ENV.BENCH_USER_NAME || `Bench User ${suffix}`;
  const agentName = __ENV.BENCH_AGENT_NAME || `Bench Agent ${suffix}`;

  createParticipant(userId, 'user', userName);
  createParticipant(agentId, 'agent', agentName);

  const sessionRes = http.post(
    `${API_BASE}/sessions`,
    JSON.stringify({
      initiator_id: userId,
      peer_id: agentId,
      metadata: { bench: true, seed: suffix },
    }),
    JSON_HEADERS
  );

  check(sessionRes, {
    'created session': (res) => res.status === 201,
  });

  const sessionId = sessionRes.json('session.id');
  if (!sessionId) {
    throw new Error(`session creation failed: body=${sessionRes.body}`);
  }

  const participantRole = __ENV.BENCH_PARTICIPANT_ROLE === 'agent' ? 'agent' : 'user';
  const participantId = participantRole === 'agent' ? agentId : userId;

  return {
    sessionId,
    participantId,
    cleanup: {
      sessionId,
      userId,
      agentId,
    },
  };
}

function createParticipant(id, kind, displayName) {
  const res = http.post(
    `${API_BASE}/participants`,
    JSON.stringify({
      id,
      kind,
      display_name: displayName,
    }),
    JSON_HEADERS
  );

  if (res.status !== 201) {
    throw new Error(`participant ${id} seed failed: status=${res.status} body=${res.body}`);
  }
}

function buildUrl(participantId) {
  const baseUrl = __ENV.WS_URL || 'ws://localhost:4000/socket/websocket';
  const guestId = __ENV.PARTICIPANT_ID || participantId;
  const encodedParticipant = encodeURIComponent(guestId);
  return `${baseUrl}?participant_id=${encodedParticipant}&vsn=2.0.0`;
}

function sessionTopic(sessionId) {
  const topicId = __ENV.SESSION_ID || sessionId;
  return `session:${topicId}`;
}

function encode(event) {
  return JSON.stringify(event);
}

function decode(raw) {
  try {
    return JSON.parse(raw);
  } catch (_err) {
    return null;
  }
}

function nowMs() {
  return Date.now();
}

export default function (data) {
  const participantId = data?.participantId;
  const sessionId = data?.sessionId;
  if (!participantId || !sessionId) {
    throw new Error('setup data missing participant or session id');
  }

  const wsUrl = buildUrl(participantId);
  const topic = sessionTopic(sessionId);
  const debug = __ENV.DEBUG === '1';

  ws.connect(wsUrl, { tags: { session: sessionId, participant: participantId } }, (socket) => {
    const inFlight = new Map();
    let joined = false;
    let joinRef = 1;
    let messageSeq = 0;

    socket.on('open', () => {
      const joinMessage = [
        `${joinRef}`,
        `${joinRef}`,
        topic,
        'phx_join',
        {},
      ];
      const start = nowMs();
      socket.send(encode(joinMessage));

      socket.setTimeout(function () {
        if (!joined) {
          messageFailures.add(1);
          socket.close();
        }
      }, 10000);

      socket.on('message', (raw) => {
        const frame = decode(raw);
        if (!frame) {
          return;
        }

        if (!Array.isArray(frame) || frame.length < 5) {
          return;
        }

        const [_joinRefMsg, refMsg, topicMsg, eventMsg, payloadMsg] = frame;

        if (eventMsg === 'phx_reply' && refMsg === `${joinRef}` && topicMsg === topic) {
          if (debug) {
            console.log(`join reply: ${JSON.stringify(frame)}`);
          }
          joined = true;
          joinLatency.add(nowMs() - start);
          return;
        }

        if (eventMsg === 'message' && topicMsg === topic) {
          if (debug) {
            console.log(`message event: ${JSON.stringify(frame)}`);
          }
          const payload = payloadMsg || {};
          const content = payload.content || {};
          const clientRef = content.client_ref;
          if (clientRef && inFlight.has(clientRef)) {
            const sentAt = inFlight.get(clientRef);
            appendLatency.add(nowMs() - sentAt);
            inFlight.delete(clientRef);
          }
          return;
        }
      });
    });

    socket.setInterval(function () {
      if (!joined) {
        return;
      }
      const clientRef = `${participantId}-${__VU}-${messageSeq}-${nowMs()}`;
      const ref = `${joinRef + messageSeq}`;
      const payload = {
        content: {
          kind: 'text',
          content: {
            text: `ping from ${participantId} vu=${__VU}`,
            client_ref: clientRef,
          },
          metadata: {
            load: true,
            seq: messageSeq,
          },
        },
      };
      const sendMessage = [
        null,
        ref,
        topic,
        'send',
        payload,
      ];

      inFlight.set(clientRef, nowMs());
      socket.send(encode(sendMessage));
      messageSeq += 1;
    }, Number(__ENV.SEND_INTERVAL || 5000) / 1000);

    socket.setInterval(function () {
      if (!joined) {
        return;
      }
      if (inFlight.size > 50) {
        messageFailures.add(1);
        inFlight.clear();
      }
    }, 10);

    socket.on('error', () => {
      messageFailures.add(1);
    });

    socket.setTimeout(function () {
      if (debug) {
        console.log('closing socket');
      }
      socket.close();
    }, Number(__ENV.RUNTIME_MS || 60000) / 1000);
  });
}

export function teardown(data) {
  const cleanup = data?.cleanup;
  if (!cleanup) {
    return;
  }

  const { sessionId, userId, agentId } = cleanup;
  safeDelete(`${API_BASE}/sessions/${sessionId}`);
  safeDelete(`${API_BASE}/participants/${userId}`);
  safeDelete(`${API_BASE}/participants/${agentId}`);
}

function safeDelete(url) {
  const res = http.del(url, null, JSON_HEADERS);
  if (res.status !== 204 && res.status !== 404) {
    console.error(`cleanup ${url} failed with status=${res.status}`);
  }
}
