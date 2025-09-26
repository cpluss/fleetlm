---
title: Deploy Locally
sidebar_position: 1
---

# Deploying FleetLM Locally

Use the provided Docker assets to run FleetLM on your workstation.

## Requirements

- Docker Engine 24+
- Docker Compose plugin (comes with recent Docker Desktop installs)
- Ports `4000` (Phoenix) and `5432` (Postgres) available locally

## Quick start

1. Copy the sample environment if you want to override secrets:
   ```bash
   cp .env.example .env  # optional
   ```
   The Compose file already includes safe defaults (`SECRET_KEY_BASE` is randomised each run), but you can export your own values via `.env`.

2. Build the release image and start the stack:
   ```bash
   docker compose up --build
   ```
   This runs Postgres and FleetLM. The application container executes migrations on boot before Phoenix starts.

3. Visit [http://localhost:4000](http://localhost:4000) to verify the UI.

## Managing the database

- Run migrations manually:
  ```bash
  docker compose run --rm \
    -e MIGRATE_ON_BOOT=false \
    app /app/fleetlm/bin/fleetlm eval "Fleetlm.Release.migrate"
  ```
- Reset the database:
  ```bash
  docker compose down -v
  docker compose up --build
  ```

## Stopping the stack

Press `Ctrl+C` to stop the containers, or run:
```bash
docker compose down
```

This setup mirrors the production release image, making it a convenient sandbox for development and demos.
