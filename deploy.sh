#!/usr/bin/env bash
# Deploy the shopping stack to the local Kubernetes cluster.
# Secret values are generated here and kept only in the cluster.
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=shopping:9836d194
gen() { docker run --rm --entrypoint python "$IMAGE" -c "$1" | tr -d '\r'; }

kubectl apply -f manifests/00-namespace.yaml
if ! kubectl -n shopping get secret shopping-secret >/dev/null 2>&1; then
  SK=$(gen "import secrets; print(secrets.token_urlsafe(50))")
  EK=$(gen "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
  PW=$(gen "import secrets; print(secrets.token_urlsafe(18))")
  kubectl -n shopping create secret generic shopping-secret \
    --from-literal=DJANGO_SECRET_KEY="$SK" \
    --from-literal=ENCRYPTION_KEY="$EK" \
    --from-literal=DATABASE_PASSWORD="$PW" >/dev/null
  echo "secret created"
fi

kubectl apply -f manifests/10-config.yaml -f manifests/20-postgres.yaml -f manifests/21-redis.yaml
kubectl -n shopping rollout status statefulset/postgres --timeout=180s
kubectl -n shopping rollout status statefulset/redis --timeout=120s

kubectl apply -f manifests/30-migrate-job.yaml
if ! kubectl -n shopping wait --for=condition=complete job/migrate --timeout=240s; then
  kubectl -n shopping get pods
  kubectl -n shopping logs job/migrate --tail=30
  exit 1
fi
kubectl -n shopping logs job/migrate --tail=3

kubectl apply -f manifests/40-api.yaml -f manifests/50-workers.yaml
kubectl -n shopping rollout status deployment/shopping-api --timeout=200s

kubectl apply -f addons/metrics-server-v0.9.1.yaml
kubectl apply -f manifests/60-api-hpa.yaml
kubectl -n shopping get pods
