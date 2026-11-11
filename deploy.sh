#!/usr/bin/env bash
# Deploy the shopping stack to the local kind cluster (kind/cluster.yaml).
# Secret values are generated here and kept only in the cluster.
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=shopping:9836d194
REGISTRY=localhost:5000
NODE=shopping-control-plane
gen() { docker run --rm --entrypoint python "$IMAGE" -c "$1" | tr -d '\r'; }

if [ "$(kubectl config current-context)" != kind-shopping ]; then
  echo "current context is not kind-shopping; run: kind create cluster --config kind/cluster.yaml" >&2
  exit 1
fi

# Local registry (container on 127.0.0.1:5000); the cluster pulls from it.
if ! docker ps --format '{{.Names}}' | grep -qx registry; then
  docker start registry 2>/dev/null ||
    docker run -d -p 127.0.0.1:5000:5000 -v shopping-registry:/var/lib/registry --name registry registry:3.1.2
fi
docker tag "$IMAGE" "$REGISTRY/$IMAGE"
docker push "$REGISTRY/$IMAGE"
# Inside the kind node, localhost is the node itself: join the registry to the
# kind network and point localhost:5000 at it (read via config_path).
docker network connect kind registry 2>/dev/null || true
MSYS_NO_PATHCONV=1 docker exec "$NODE" sh -c \
  'mkdir -p /etc/containerd/certs.d/localhost:5000 &&
   printf "[host.\"http://registry:5000\"]\n" > /etc/containerd/certs.d/localhost:5000/hosts.toml'

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
if ! kubectl -n shopping get secret shopping-tls >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  # MSYS_NO_PATHCONV keeps -subj intact on Git Bash, so the file paths are
  # passed to the Windows openssl already converted (cygpath -m).
  OUT=$TMP; command -v cygpath >/dev/null && OUT=$(cygpath -m "$TMP")
  MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" -keyout "$OUT/tls.key" -out "$OUT/tls.crt" 2>/dev/null
  kubectl -n shopping create secret tls shopping-tls --cert="$TMP/tls.crt" --key="$TMP/tls.key" >/dev/null
  rm -rf "$TMP"
  echo "tls secret created"
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

kubectl apply --server-side -f addons/envoy-gateway-v1.9.3-install.yaml >/dev/null
kubectl -n envoy-gateway-system wait --for=condition=Available deployment/envoy-gateway --timeout=300s
kubectl apply -f manifests/70-gateway.yaml
# Only the Gateway's Envoy may reach the API (kindnet enforces it).
kubectl apply -f manifests/80-networkpolicy.yaml
kubectl -n shopping get pods
