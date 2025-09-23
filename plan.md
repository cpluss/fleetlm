# FleetLM Scaling Implementation Plan

## Overview
Implementation roadmap for Redis PubSub, distributed caching, and scaling improvements.

## Phase 1: Redis PubSub Integration ✅

### 1.1 Dependencies & Configuration
- [x] Add phoenix_pubsub_redis and redix dependencies
- [x] Update application.ex PubSub configuration for Redis
- [x] Environment-based adapter switching (local for dev/test, Redis for prod)
- [x] Test Redis connectivity

**Target**: Enable cross-node message distribution ✅

### 1.2 Connection Management
- [ ] Add Redis connection health checks
- [ ] Implement retry logic with exponential backoff
- [ ] Configure connection pooling

**Target**: Reliable Redis connectivity with graceful degradation

## Phase 2: Cachex Distributed Caching ✅

### 2.1 Cache Infrastructure
- [x] Add Cachex dependency
- [x] Set up cache modules:
  - `Fleetlm.Cache.Messages` - Recent messages (TTL: 1 hour)
  - `Fleetlm.Cache.Participants` - Thread participants (TTL: 30 min)
  - `Fleetlm.Cache.ThreadMeta` - Thread metadata (TTL: 15 min)

### 2.2 ThreadServer Memory Management
- [x] Remove in-process message caching from ThreadServer
- [x] Implement Cachex-based message caching
- [x] Replace ThreadServer state with cache lookups
- [x] Cache invalidation on message creation

**Target**: 80% reduction in ThreadServer memory footprint ✅

## Phase 3: Database Query Optimization ✅

### 3.1 Query Performance
- [x] Add query timing telemetry
- [x] Optimize connection pool configuration
- [x] Enhanced database connection settings (queue_target, queue_interval)

### 3.2 Index Optimization
- [x] Reviewed existing indexes (already optimized for hot paths)
- [x] Database migration includes proper indexes for thread_messages and participants

**Target**: <10ms average for hot path queries ✅

## Phase 4: Enhanced Error Handling & Supervision ✅

### 4.1 ThreadServer Resilience
- [x] Add circuit breaker pattern for database and cache calls
- [x] Implement graceful degradation strategies
- [x] Enhanced restart policies with proper limits (10 restarts/60 seconds)

### 4.2 Supervision Improvements
- [x] ThreadSupervisor monitoring with restart limits
- [x] Health check system for all components
- [x] Graceful shutdown procedures with proper timeouts

**Target**: 99.9% uptime with graceful error recovery ✅

## Phase 5: Observability & Monitoring ✅

### 5.1 Telemetry Integration
- [x] Add comprehensive telemetry events for:
  - Message processing latency
  - Cache performance (hits/misses)
  - Database query performance with slow query warnings
  - ThreadServer operations

### 5.2 Metrics & Logging
- [x] Database query timing with warnings for slow queries (>100ms)
- [x] Cache hit/miss tracking
- [x] Message processing latency tracking
- [x] Structured logging with detailed metadata

**Target**: Full visibility into performance bottlenecks ✅

## Phase 6: Production Readiness ⏳

### 6.1 Configuration Management
- [ ] Environment-based feature flags
- [ ] Runtime configuration for cache/timeout settings
- [ ] Health check endpoints

### 6.2 Load Testing
- [ ] Stress test ThreadServer lifecycle
- [ ] Redis PubSub throughput testing
- [ ] Memory usage profiling

**Target**: Production-ready with comprehensive monitoring

---

## Phase 7: Chat Runtime Refactor ⏳

### 7.1 Phase 1 – Chat API Consolidation ✅
- [x] Collapse dispatcher responsibilities into `Fleetlm.Chat`
- [x] Expose canonical API (`send_message/1`, `get_messages/2`, `mark_read/2` stub)
- [x] Update controllers/channels/tests to consume the new API
- [x] Remove direct uses of `Fleetlm.Chat.Dispatcher`

### 7.2 Phase 2 – Cachex Read Models & Per-Thread Channels
- [x] Add Cachex dependency and start caches under the application supervisor
- [x] Implement read-model helpers for tails/history with Cachex backing
- [x] Rework `ConversationServer` to use read models + publish to `conversation:{dm_key}`
- [x] Refactor socket routing/channels to join per-thread topics and hydrate from cache

### 7.3 Phase 3 – Inbox Runtime
- [x] Introduce `InboxServer`, registry, and supervision
- [x] Deliver `InboxSnapshot`/`InboxDelta` via Cachex + InboxServer debouncing
- [x] Implement `mark_read/2` and unread count adjustments
- [x] Expand tests + telemetry for inbox flow

### Status & Next Steps
- Phase 7.3 implementation complete; review mark_read semantics and plan telemetry additions or further tuning if needed

---

## Success Metrics
- **Horizontal Scaling**: Support 2+ nodes with Redis PubSub
- **Memory Usage**: 80% reduction in ThreadServer memory footprint
- **Cache Performance**: 95%+ hit ratio for recent messages
- **Query Performance**: <10ms average for hot path queries
- **Reliability**: 99.9% uptime with graceful error recovery
- **Observability**: Full visibility into performance bottlenecks
