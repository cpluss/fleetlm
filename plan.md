# FleetLM Scaling Roadmap

## Phase 1 – Instrumentation & Baseline
- [x] Add telemetry spans/counters for append latency, fan-out time, queue depth, and cache hit rate
- [x] Wire metrics into PromEx dashboards with p50/p95/p99 panels
- [x] Build lightweight k6/WebSocket load script + docs; capture current append→deliver latency + resource usage
- [x] Document baseline findings (bottlenecks, limits) in `docs/perf/phase1.md`

## Phase 2 – Gateway & Runtime Boundary Refactor
- [x] Extract stateless gateway service interfaces (append, replay, mark-read)
- [x] Update channels/controllers/tests to use the gateway boundary instead of direct Repo access
- [x] Ensure instrumentation from Phase 1 still reports through the new boundary
- [x] Note follow-up integration risks in plan checklist (Gateway still delegates to `Sessions` today; Phase 3 must replace delegation with shard RPC and extend telemetry tags for slot ownership.)

## Phase 3 – Cluster & Shard Orchestration
- [x] Introduce consistent hash ring abstraction (256–1024 slots) with persistence + config knobs
- [x] Add libcluster + Horde supervision tree for shard ownership and dynamic distribution
- [x] Implement gateway lookup + retry semantics for shard ownership changes
- [x] Provide ops docs for shard topology configuration and health checks

## Phase 4 – Hot Path State & Durability
- [x] Design and implement ETS session rings + idempotency cache per shard slot
- [x] Integrate `:disk_log` append-before-ack with rotation + fsync policy
- [x] Build async Postgres persistence worker fed from disk log tail
- [x] Extend instrumentation to capture disk write latency and expose slot-level metrics (cache footprint gauge follow-up noted)

## Phase 5 – Client Protocol & Replay
- [ ] Extend channel protocol to include seq/ack, TRY_AGAIN, and cursor resume parameters
- [ ] Support hot (ETS) + cold (`:disk_log`) replay flows, including gap fill validation
- [ ] Update SDK/docs/examples to adopt new protocol (agents + humans)
- [ ] Add reconnection tests (LiveView, channel, CLI) covering resume scenarios

## Phase 6 – Rebalance & Resilience
- [ ] Implement shard drain → handoff pipeline with queued append forwarding
- [ ] Add automated retries/backoff in gateways during drain + failure
- [ ] Expose shard state + queue metrics via telemetry dashboards
- [ ] Create runbook covering rolling deploys, node exits, and failure drills

## Phase 7 – Scale Validation & Publication
- [ ] Automate Fly.io (or equivalent) 3-node test harness with 10k WS clients
- [ ] Record append→first-byte latency (p50/p95/p99), TRY_AGAIN rate, memory usage, and disk log growth
- [ ] Induce rolling restart + shard moves; verify zero-gap delivery with cursor replay
- [ ] Publish results + methodology in docs + landing page copy

---

Progress tracking lives in this checklist. Complete a phase before moving on, update this file as tasks are finished, and report back after each phase.
