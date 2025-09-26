# FleetLM Session Architecture Blueprint

## Entities

### participants
- `id` (string, e.g. `user:alice`, `agent:returns_bot`)
- `kind` (`user` | `agent` | `system`)
- `display_name`
- `status` (`active`, `disabled`)
- `metadata` (JSONB for labels, avatar URLs, etc.)
- timestamps

### chat_sessions
- `id` (ULID string)
- `initiator_id` (FK to participants.id)
- `peer_id` (FK to participants.id)
- `agent_id` (FK to participants.id, nullable shortcut when either participant is an agent)
- `kind` (`human_dm`, `agent_dm`)
- `status` (`open`, `closed`, `archived`)
- `metadata` (JSONB)
- `last_message_id` (FK to chat_messages.id, nullable)
- `last_message_at` (UTC timestamp, nullable)
- `inserted_at`, `updated_at`


### chat_messages
- `id` (ULID string)
- `session_id` (FK to chat_sessions.id)
- `sender_id` (FK to participants.id)
- `kind` (`text`, `tool_call`, `system`, future variants)
- `content` (JSONB, e.g. `{ "text": "Hello" }`)
- `metadata` (JSONB for embeddings, reference ids, etc.)
- `shard_key` (integer hash of session_id for distribution)
- `inserted_at`, `updated_at`


### agent_endpoints
- `id` (ULID string)
- `agent_id` (FK to participants.id)
- `origin_url`
- `auth_strategy` (`none`, `bearer`, `hmac`)
- `auth_value` (encrypted credential reference)
- `headers` (JSONB map of static headers)
- `timeout_ms`
- `retry_policy` (JSONB: attempts, backoff)
- `status` (`enabled`, `disabled`)
- timestamps


### agent_delivery_logs
- `id` (ULID string)
- `session_id` (FK to chat_sessions.id)
- `message_id` (FK to chat_messages.id)
- `agent_id` (FK to participants.id)
- `attempt`
- `status` (`sent`, `retry`, `failed`)
- `http_status`
- `latency_ms`
- `response_excerpt`
- `error_reason`
- `inserted_at`

## Naming Conventions
- Participant identifiers: `user:<slug>`, `agent:<slug>`, `system:<slug>`
- Session kinds: `human_dm` for user↔user, `agent_dm` for user↔agent
- Message kinds: `text`, `tool_call`, `system`; future-safe by storing `content` as JSONB

## Message Payload Contract
```json
{
  "id": "01JABCDXYZ1234567890ABCDEZ",
  "session_id": "01JABCDE1234567890ABCDEFX",
  "kind": "text",
  "content": {"text": "Hello"},
  "metadata": {"role": "user"},
  "sender_id": "user:alice",
  "inserted_at": "2024-07-01T12:34:56Z"
}
```

Clients must treat `content` as schema-per-kind and use ULID ordering for pagination (`after_id`).

## Migration Approach
- MVP drops legacy `dm_*` tables; developers reset databases during the rollout.
- Seeds create canonical participants (sample users + agents) and link them through sessions.
- Production migration later can copy data into the new tables before removing old schema.

## Open Questions
- Should agent delivery retries be persisted as separate rows or JSON array? → Chosen: separate rows (`agent_delivery_logs`).
