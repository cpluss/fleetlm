---
title: Deploy on Fly.io
sidebar_position: 2
---

# Deploying FleetLM on Fly.io

This guide walks through self-hosting FleetLM on [Fly.io](https://fly.io/). It focuses on the high-level steps needed to launch an app, wire up Postgres, and enable clustering.

## Prerequisites

- A Fly.io account and the `flyctl` CLI (`brew install flyctl` or see Fly docs).
- Docker installed locally if you want to inspect the image (optional).
- A Postgres database (Fly has a managed option) and a generated `SECRET_KEY_BASE` (`mix phx.gen.secret`).

## 1. Use the public image

FleetLM publishes a production-ready image at `ghcr.io/cpluss/fleetlm:latest`. Pull it locally if you want to inspect it, but Fly can deploy directly from the registry:
```bash
docker pull ghcr.io/cpluss/fleetlm:latest
```

## 2. Create the Fly app

1. Log in and initialize the app (skip deployment for now):
   ```bash
   fly auth login
   fly launch --no-deploy --name fleetlm-app --region iad
   ```
   Replace `fleetlm-app` and the region as desired.

## 3. Configure secrets

Set the environment variables that the release expects:
```bash
fly secrets set \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  DATABASE_URL="ecto://USER:PASS@HOST/DATABASE" \
  MIGRATE_ON_BOOT=true \
  DNS_CLUSTER_QUERY=tasks.fleetlm-app.internal \
  DNS_CLUSTER_NODE_BASENAME=fleetlm \
  DNS_POLL_INTERVAL_MS=5000
```

If you use Fly Postgres:
```bash
fly postgres create --name fleetlm-db --region iad
fly postgres attach fleetlm-db
```
Fly automatically injects the connection string into `DATABASE_URL` when you attach the database.

## 4. Deploy

Deploy using the published image: 
```bash
fly deploy --image ghcr.io/cpluss/fleetlm:latest
```
The Dockerfile already runs migrations on boot (via the entrypoint), so your first deploy will create the database schema automatically.

## 5. Verify

- Logs: `fly logs`
- Open the app: `fly open`
- Check clustering: `fly ssh console -C "/app/fleetlm/bin/fleetlm remote 'Node.list()'"`

## 6. Scale & maintain

- Scale instances: `fly scale count 3`
- Manual migrations (if you disable `MIGRATE_ON_BOOT`):
  ```bash
  fly ssh console -C "/app/fleetlm/bin/fleetlm eval 'Fleetlm.Release.migrate'"
  ```
- Roll back:
  ```bash
  fly releases
  fly deploy --image ghcr.io/cpluss/fleetlm:<previous-tag>
  fly ssh console -C "/app/fleetlm/bin/fleetlm eval 'Fleetlm.Release.rollback(Fleetlm.Repo, <version>)'"
  ```

With Fly handling networking and scaling, the published FleetLM release image gives you a fast path to a clustered deployment.
