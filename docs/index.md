---
title: FleetLM
slug: /
sidebar_position: 1
---

# FleetLM

FleetLM lets you deploy language-model agents like web services. Use your favourite framework ([Next.js](https://nextjs.org/), [Vercel AI SDK](https://ai-sdk.dev/docs/introduction), [Pydantic-AI](https://ai.pydantic.dev/), [FastAPI](https://fastapi.tiangolo.com/), [Rails](https://rubyonrails.org/), etc) and FleetLM handles the streaming, websockets, clustering, and operational plumbing so you can focus on delivering an amazing user experience.

## Why FleetLM

- **Framework-agnostic**: Integrate agents regardless of language or runtime without re-implementing chat infrastructure.
- **Horizontal scale built in**: Clustering and release-ready assets let you scale out globally from day one.
- **Operational excellence**: Stream-safe transports treat agents as first-class backend services.
- **Client & Server SDKs**: Plug and play integrations with the most popular frameworks today (React, Python, Nodejs) to get you up and running with minimal lines of code.

## Ways to deploy

Pick the path that matches your environment:

- [Local deployment](deployment/local.md) – run the stack with Docker Compose on your machine.
- [Deploy on Fly.io](deployment/fly-io.md) – use the published FleetLM image to deploy globally.
- [Deploy on Kubernetes](deployment/kubernetes.md) – apply the all-in-one manifest for cluster-native rollouts.

## Understand the internals

Dive deeper when you need to customise behaviour or debug:

- [Clustering internals](internals/clustering.md) – how libcluster discovers peers and how to tune it.
- [Database migration workflow](internals/database-migrations.md) – how releases run migrations safely on boot.

Questions or issues? Visit [github.com/cpluss/fleetlm](https://github.com/cpluss/fleetlm).