---
title: Deployment
sidebar_position: 1
---

# Deployment

FleetLM ships as a container image (`ghcr.io/cpluss/fleetlm`). Run it alongside a PostgreSQL instance; FleetLM itself is stateless. This page lists the environment variables the release expects and shows a single `docker run` invocation.

## Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `DATABASE_URL` | ✅ | Ecto-style connection string (e.g. `ecto://user:pass@postgres-host:5432/fleetlm`). |
| `SECRET_KEY_BASE` | ✅ | 64-byte secret used for signing sessions and encrypting cookies. Generate with `openssl rand -hex 64` or your secret manager. |
| `PHX_HOST` | ✅ | External hostname clients use to reach FleetLM (e.g. `api.example.com`). |
| `PORT` | Optional | Port FleetLM binds to. Defaults to `4000`. |
| `MIGRATE_ON_BOOT` | Optional | `true` runs database migrations before starting the server (default `true`). |
| `DNS_CLUSTER_QUERY` | Optional | DNS name queried for cluster discovery. Leave unset for single-node deployments. |
| `DNS_CLUSTER_NODE_BASENAME` | Optional | Node basename used with `DNS_CLUSTER_QUERY`. |
| `DNS_POLL_INTERVAL_MS` | Optional | Poll interval for DNS clustering (defaults to `5000`). |

Ensure PostgreSQL is reachable and created ahead of time (FleetLM will run migrations if `MIGRATE_ON_BOOT=true`).

## Docker invocation

```bash
docker run -d --name fleetlm   -p 4000:4000   -e DATABASE_URL="ecto://user:pass@postgres-host:5432/fleetlm"   -e SECRET_KEY_BASE="$(openssl rand -hex 64)"   -e PHX_HOST="api.example.com"   -e PORT=4000   -e MIGRATE_ON_BOOT=true   ghcr.io/cpluss/fleetlm:latest
```

The container exposes HTTP on port `4000` by default (`/api` for REST, `/socket` for WebSocket). Adjust the port mapping or environment variables as needed for your infrastructure, and configure DNS/load balancing according to your platform.
