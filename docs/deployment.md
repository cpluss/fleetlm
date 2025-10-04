---
title: Deployment
sidebar_position: 4
---

# Deployment

Start with the Docker Compose release image, then layer on production settings as you grow.

## Local / single-node

```bash
git clone https://github.com/cpluss/fleetlm.git
cd fleetlm

echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" > .env
echo "PHX_HOST=localhost" >> .env

docker compose up --build
```

- FleetLM listens on `http://localhost:4000`
- Postgres runs inside the same Compose file
- Migrations run automatically when `MIGRATE_ON_BOOT=true`

## Production checklist

Set the following environment variables for releases:

- `SECRET_KEY_BASE` — 64 byte secret
- `DATABASE_URL` — Postgres connection string
- `PHX_HOST` and `PORT` — external hostname and port
- `DNS_CLUSTER_QUERY` / `DNS_CLUSTER_NODE_BASENAME` — enable libcluster for multi-node deployments

Run `docker compose up --build` for small installs, or package the release image into your orchestrator of choice (Kubernetes, ECS, Nomad, etc.). Each node is stateless beyond Postgres; horizontal scaling is just adding more containers with the same configuration.
