import ws from 'k6/ws';
import { Trend, Counter } from 'k6/metrics';

const appendLatency = new Trend('append_latency_ms', true);
const joinLatency = new Trend('join_latency_ms', true);
const messageFailures = new Counter('append_failures');

export const options = {
  vus: Number(__ENV.VUS || 50),
  duration: __ENV.DURATION || '1m',
  thresholds: {
    append_latency_ms: ['p(95)<150'],
  },
};

function buildUrl() {
  const baseUrl = __ENV.WS_URL || 'ws://localhost:4000/socket/websocket';
  const participantId = __ENV.PARTICIPANT_ID
    ? __ENV.PARTICIPANT_ID
    : __ENV.PARTICIPANT_PREFIX
      ? `${__ENV.PARTICIPANT_PREFIX}-${__VU}`
      : `load-${__VU}`;
  const encodedParticipant = encodeURIComponent(participantId);
  return `${baseUrl}?participant_id=${encodedParticipant}&vsn=2.0.0`;
}

function nextSessionId() {
  if (__ENV.SESSION_ID) {
    return __ENV.SESSION_ID;
  }
  const shard = Math.ceil(__VU / Number(__ENV.SESSIONS_PER_GROUP || 10));
  return `load-session-${shard}`;
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

export default function () {
  const url = buildUrl();
  const sessionId = nextSessionId();
  const topic = `session:${sessionId}`;
  const debug = __ENV.DEBUG === '1';

  ws.connect(url, { tags: { session: sessionId } }, (socket) => {
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

        const [joinRefMsg, refMsg, topicMsg, eventMsg, payloadMsg] = frame;

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
      const clientRef = `${__VU}-${messageSeq}-${nowMs()}`;
      const ref = `${joinRef + messageSeq}`;
      const payload = {
        content: {
          kind: 'text',
          content: {
            text: `ping from ${__VU}`,
            client_ref: clientRef,
          },
          metadata: {
            load: true,
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

    socket.on('error', (e) => {
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
