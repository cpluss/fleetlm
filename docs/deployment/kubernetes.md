---
title: Deploy on Kubernetes
sidebar_position: 3
---

# Deploying FleetLM on Kubernetes

This guide covers a straightforward, production-friendly deployment of FleetLM on any CNCF-conformant Kubernetes cluster (GKE, EKS, AKS, k3s, etc.).

## Prerequisites

- `kubectl` configured for your cluster.
- Postgres available to the cluster (managed service or an operator-managed instance).
- Generated secrets: `SECRET_KEY_BASE` (`mix phx.gen.secret`) and a Postgres connection string.

## 1. One-shot manifest

The manifests below reference the published image `ghcr.io/cpluss/fleetlm:latest`, so you don’t need to build or pull anything locally. Fill in your secrets (base64-encoded) and apply the entire stack with one command.

```yaml
# fleetlm.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: fleetlm
---
apiVersion: v1
kind: Secret
metadata:
  name: fleetlm-secrets
  namespace: fleetlm
type: Opaque
data:
  SECRET_KEY_BASE: <base64-secret-key-base>
  DATABASE_URL: <base64-ecto-connection-string>
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fleetlm-config
  namespace: fleetlm
data:
  PHX_HOST: fleetlm.example.com
  PORT: "4000"
  MIGRATE_ON_BOOT: "true"
  DNS_CLUSTER_QUERY: fleetlm-headless.fleetlm.svc.cluster.local
  DNS_CLUSTER_NODE_BASENAME: fleetlm
  DNS_POLL_INTERVAL_MS: "5000"
---
apiVersion: v1
kind: Service
metadata:
  name: fleetlm-headless
  namespace: fleetlm
  annotations:
    fleetlm.io/purpose: "Headless service enables pod-to-pod discovery for libcluster"
spec:
  clusterIP: None
  selector:
    app: fleetlm
  ports:
    - name: http
      port: 4000
      targetPort: 4000
---
apiVersion: v1
kind: Service
metadata:
  name: fleetlm
  namespace: fleetlm
  annotations:
    fleetlm.io/purpose: "Public load-balanced service"
spec:
  type: LoadBalancer
  selector:
    app: fleetlm
  ports:
    - name: http
      port: 80
      targetPort: 4000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fleetlm
  namespace: fleetlm
spec:
  replicas: 2
  selector:
    matchLabels:
      app: fleetlm
  template:
    metadata:
      labels:
        app: fleetlm
    spec:
      containers:
        - name: fleetlm
          image: ghcr.io/cpluss/fleetlm:latest
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: fleetlm-secrets
            - configMapRef:
                name: fleetlm-config
          ports:
            - containerPort: 4000
          readinessProbe:
            httpGet:
              path: /
              port: 4000
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 4000
            initialDelaySeconds: 30
            periodSeconds: 30
```

Apply everything with a single command:
```bash
kubectl apply -f fleetlm.yaml
```

> ℹ️ The headless service (`clusterIP: None`) exposes each pod’s DNS entry so libcluster can form a node mesh. The regular `LoadBalancer` service handles user-facing traffic.
> ℹ️ Run `printf 'value' | base64` to encode `SECRET_KEY_BASE` and `DATABASE_URL`. Kubernetes secrets require base64 encoding (not encryption).

## 2. Migrations & rollouts

- The container entrypoint runs `Fleetlm.Release.migrate/0` before Phoenix starts (controlled by `MIGRATE_ON_BOOT`). Leave it enabled for one pod during initial rollout. If you want explicit control, set `MIGRATE_ON_BOOT=false` and run:
  ```bash
  kubectl exec deploy/fleetlm -- /app/fleetlm/bin/fleetlm eval "Fleetlm.Release.migrate"
  ```
- Rolling updates happen automatically as you deploy new images via `kubectl set image` or reapply the Deployment manifest.

## 3. Verification & scaling

- View pod status: `kubectl get pods -n fleetlm`
- Inspect logs: `kubectl logs deploy/fleetlm -n fleetlm`
- Verify clustering: `kubectl exec deploy/fleetlm -n fleetlm -- /app/fleetlm/bin/fleetlm remote 'Node.list()'`
- Scale up/down: `kubectl scale deploy/fleetlm --replicas=4 -n fleetlm`

## 4. Ingress / TLS

Expose the service via your preferred ingress controller (NGINX, Traefik, etc.) or keep the `Service` of type `LoadBalancer`. Remember to configure TLS termination either at the ingress layer or inside the app by supplying certificates and enabling HTTPS in `config/runtime.exs`.

With these pieces in place, FleetLM runs as a horizontally scalable Phoenix release, ready for multi-node clustering and straightforward upgrades.
