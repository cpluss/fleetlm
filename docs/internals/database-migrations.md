---
title: Database Migration Workflow
sidebar_position: 2
---

# Database Migration & Rollout Guide

FleetLM ships as a release that executes Ecto migrations automatically before the node boots. This section covers the lifecycle for running migrations locally, in CI, and in production.

## Release helper & entrypoint

* `lib/fleetlm/release.ex` exposes `Fleetlm.Release.migrate/0` and `rollback/2` for running migrations inside the release.
* `docker-entrypoint.sh` invokes `Fleetlm.Release.migrate/0` whenever the container starts with a `start`, `start_iex`, `daemon`, or `daemon_iex` command and the `MIGRATE_ON_BOOT` environment variable is `true` (default).

You can opt-out of automatic migrations by setting `MIGRATE_ON_BOOT=false` on any container.

## Local workflow

1. Run migrations with Mix as usual:

   ```bash
   mix ecto.migrate
   mix ecto.rollback
   ```

2. To simulate the release path:

   ```bash
   MIX_ENV=prod mix release
   _build/prod/rel/fleetlm/bin/fleetlm eval "Fleetlm.Release.migrate"
   ```

## Docker & production rollout

1. Build/rebuild the image:

   ```bash
   docker build . -t fleetlm
   ```

2. When containers launch, migrations run automatically before the VM transitions to Phoenix:

   ```bash
   docker compose up --build
   # entrypoint -> Fleetlm.Release.migrate -> Fleetlm Application
   ```

3. For one-off migrations (CI/CD, manual operations):

   ```bash
   docker compose run --rm \
     -e MIGRATE_ON_BOOT=false \
     app /app/fleetlm/bin/fleetlm eval "Fleetlm.Release.migrate"
   ```

4. Rolling deploys (Fly.io, Kubernetes, ECS, etc.)
   * Keep `MIGRATE_ON_BOOT=true` on exactly one replica (or run the command as a pre-deploy job). Other replicas can skip migrations via `MIGRATE_ON_BOOT=false` if you want stricter control.
   * Confirm migrations succeeded before scaling up additional replicas: `bin/fleetlm eval "Ecto.Migrator.migrations(Fleetlm.Repo)"`.

## Rollbacks

* Use `Fleetlm.Release.rollback/2` to target a specific migration:

  ```bash
  bin/fleetlm eval "Fleetlm.Release.rollback(Fleetlm.Repo, 20240412120000)"
  ```

* Remember to redeploy the prior release if the schema change is incompatible with current code.

## CI considerations

* `mix precommit` already runs `mix deps.unlock --unused`, `mix format`, and the test suite. When run in a shared environment set `MIX_TEST_PARTITION` to isolate databases, e.g. `MIX_TEST_PARTITION=1 mix precommit`.
* Use `mix ecto.migrations` to detect mismatched migrations (a missing migration file shows as `** FILE NOT FOUND **`).
