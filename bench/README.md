# FleetLM Performance Benchmarks

A comprehensive benchmarking suite for FleetLM's chat runtime, designed to measure performance, identify bottlenecks, and ensure scalability.

## Quick Start

```bash
# Run all benchmarks with standard datasets
mix run bench/run_all.exs

# Quick performance check with lightweight data
mix run bench/run_all.exs --light

# Query analysis to identify optimization opportunities
mix run bench/run_all.exs --analysis

# Help and available options
mix run bench/run_all.exs --help
```

## Available Benchmarks

### 🤖 Agent Workload Benchmarks
- **Single agent operations** - Baseline performance for inbox checks, session lists
- **Concurrent agent processing** - Scalability testing with multiple agents
- **Agent workflow simulation** - Realistic agent behavior patterns
- **Cache performance testing** - Warm vs cold cache scenarios

```bash
mix run bench/agent_workload_bench.exs                    # Standard performance tests
mix run bench/agent_workload_bench.exs --analysis        # Query analysis
mix run bench/agent_workload_bench.exs --dataset heavy   # Stress testing
```

### 👥 Participant Workload Benchmarks
- **Human user operations** - Inbox checks, session management, messaging
- **Session lifecycle testing** - Creation, messaging, read tracking
- **Mixed human/agent interactions** - Real-world conversation patterns
- **Scalability testing** - Performance with increasing user counts

```bash
mix run bench/participant_workload_bench.exs                # Standard performance tests
mix run bench/participant_workload_bench.exs --analysis     # Query analysis
mix run bench/participant_workload_bench.exs --scalability  # Scalability testing
```

## Dataset Sizes

| Dataset | Agents | Humans | Sessions | Use Case |
|---------|--------|--------|----------|----------|
| **light** | 3 | 5 | 8 | Quick testing, development |
| **standard** | 8 | 15 | 20 | Realistic production load |
| **heavy** | 15 | 30 | 50 | Stress testing, capacity planning |

## Performance Results Overview

After optimization improvements:

### Single Agent Inbox Check
- **Performance**: 129+ ops/second (7.71ms average)
- **Queries**: 0 queries (cached) to 2 queries (cache miss)
- **Memory**: ~2KB per operation

### Concurrent Agent Load (8 agents)
- **Performance**: 18+ ops/second (53ms average)
- **Queries**: 26 queries total (~3 per agent)
- **Memory**: ~14KB per operation

### Key Optimizations Applied
1. **Database Setup Optimization**: Moved outside benchmark iterations (eliminated 2-3s overhead)
2. **N+1 Query Elimination**: Batched unread count queries in single optimized query
3. **Performance Indexes**: Added composite indexes for message and session lookups
4. **Cache Utilization**: Pre-warmed caches for realistic performance measurement

## Understanding Results

### Performance Metrics
- **IPS (Iterations Per Second)**: Higher is better
- **Average Time**: Lower is better
- **Memory Usage**: Per-operation memory consumption
- **Query Count**: Database queries executed (fewer is better)

### Analysis Mode
Use `--analysis` to see detailed query counts and identify optimization opportunities:

```bash
mix run bench/run_all.exs --analysis
```

This shows:
- Exact query counts per operation
- Time breakdown with/without database overhead
- Cache hit/miss patterns
- Optimization recommendations

## Benchmark Architecture

### Helper Module (`bench/support/bench_helper.exs`)
- Standardized data setup with configurable sizes
- Telemetry-based query counting
- Cache management utilities
- Realistic user simulation patterns

### Key Features
- **One-time database setup** - Eliminates repeated overhead
- **Configurable datasets** - Light/standard/heavy for different testing needs
- **Query analysis** - Telemetry integration for optimization insights
- **Cache warming** - Realistic performance measurement

## Best Practices

### Running Benchmarks
1. **Use appropriate dataset size** for your testing goals
2. **Run analysis mode** to understand query patterns
3. **Multiple runs** for consistent results
4. **Monitor system resources** during heavy testing

### Interpreting Results
1. **Focus on realistic scenarios** (warm cache performance)
2. **Compare query counts** between operations
3. **Consider memory usage** for capacity planning
4. **Analyze concurrency patterns** for scalability insights

## Troubleshooting

### Common Issues
- **Database connection errors**: Ensure PostgreSQL is running
- **Slow performance**: Check if database indexes are applied
- **Memory errors**: Reduce dataset size or increase available memory
- **Timeout issues**: Increase timeout values in benchmark configuration

### Performance Debugging
```bash
# Quick performance check
mix run bench/agent_workload_bench.exs --dataset light

# Detailed query analysis
mix run bench/agent_workload_bench.exs --analysis

# Database index verification
mix run -e "IO.inspect(Ecto.Adapters.SQL.query!(Fleetlm.Repo, \"SELECT indexname FROM pg_indexes WHERE tablename = 'chat_messages'\"))"
```

## Contributing

When adding new benchmarks:
1. Follow existing patterns in `agent_workload_bench.exs`
2. Use standardized data setup from `bench_helper.exs`
3. Include both performance and analysis modes
4. Document expected performance characteristics
5. Test with all dataset sizes