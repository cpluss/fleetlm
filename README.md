# Fleetlm - the realtime runtime for humans + agents

FleetLM gives you a drop-in runtime for conversations (humans, agents, or both). Connect with WebSockets, store in postgres, fan-out over Redis, and scale horizontally without lock-in or per-MAU pricing.

It is the boring, reliable runtime for chat and agent apps. Start with `docker compose up` or use helm to run it in your kubernetes cluster, and then integrate via our SDKs to ship realtime DMs, broadcasts, and agent messages in minutes.

## Roadmap

### v0.1 - MVP
- [ ] Postgres (ecto) message persistence
- [ ] Redis pub/sub for cross-node scaling (phoenix pubsub)
- [ ] Websockets with basic JWT auth
- [ ] Threads (DMs + broadcasts)
- [ ] Last-N (40) message cache (cachex)
- [ ] Docker compose + dockerfile
- [ ] REST API for history + unread counts

### v0.2 - DX & SDKs
- [ ] Typescript SDK (@fleetlm/js)
- [ ] Python SDK (fleetlm)
- [ ] Example app using sdks + ai-sdk/pydantic-ai

### v0.3 - Agentic features
- [ ] First-class agent role (role: "agent") in messages
- [ ] Event webhooks (receipts, created, etc)
- [ ] Presence API (online / typing indicators)

### v0.4 - Scaling knobs
- [ ] Sharded redis pub/sub support
- [ ] Metrics (prometheus, latencies, etc)
- [ ] Admin dashboard (connections, threads, events/sec, hot shards)

### v0.5 - Nice to have features
- [ ] Rich media (attachments via S3/R2): photos, etc
- [ ] Rate limits & throttles (per user, configurable)
- [ ] Thread search
- [ ] Delivery receipts on individual messages + read receipts
- [ ] Batch APIs for efficient sync
- [ ] Soft deletes & retention policies (per thread TTL, GDPR delete, etc)