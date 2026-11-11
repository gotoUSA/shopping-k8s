#!/usr/bin/env bash
# NetworkPolicy test (RECORD.md, 2026-11-11, kind cluster).
#
# The API trusts X-Forwarded-Proto: https, which only the Gateway should send.
# Another pod sends that header straight to shopping-api:8000, once without
# manifests/80-networkpolicy.yaml and once with it. Then the Gateway path and
# the kubelet probes are checked with the policy on.
#
# Removes the policy first and leaves it applied at the end.
# Output: evidence/05-networkpolicy.txt
set -uo pipefail
cd "$(dirname "$0")/.."
NS=shopping
OUT=evidence/05-networkpolicy.txt
FORGE='
import http.client
for hdr in ({"Host": "localhost"}, {"Host": "localhost", "X-Forwarded-Proto": "https"}):
    try:
        c = http.client.HTTPConnection("shopping-api.shopping.svc", 8000, timeout=5)
        c.request("GET", "/health/", headers=hdr)
        r = c.getresponse()
        print("  ", sorted(hdr), "->", r.status, r.getheader("Location") or r.read().decode())
    except OSError as e:
        print("  ", sorted(hdr), "->", type(e).__name__, e)
'
forge() {
  echo "-- from celery-main (namespace $NS)"
  kubectl -n $NS exec deploy/celery-main -- python -c "$FORGE"
  echo "-- from pod forge (namespace default)"
  kubectl exec forge -- python -c "$FORGE"
}
gateway() {
  echo "-- through the Gateway (host)"
  echo "\$ curl -sk https://localhost:8443/health/"
  curl -sk -w "  [%{http_code}]\n" https://localhost:8443/health/
  echo "\$ curl -sk -o /dev/null -w '%{http_code}' https://localhost:8443/api/products/"
  curl -sk -o /dev/null -w "%{http_code}\n" https://localhost:8443/api/products/
}
probes() {
  kubectl -n $NS get pods -l app=shopping-api \
    -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
  for p in $(kubectl -n $NS get pods -l app=shopping-api -o name); do
    echo "$p: kube-probe requests in the last 90s: $(kubectl -n $NS logs "$p" --since=90s | grep -c kube-probe)," \
      "non-200: $(kubectl -n $NS logs "$p" --since=90s | grep kube-probe | grep -vc '" 200 ')"
  done
}

kubectl get pod forge >/dev/null 2>&1 ||
  kubectl run forge --image=localhost:5000/shopping:9836d194 --restart=Never --command -- sleep 86400 >/dev/null
kubectl wait --for=condition=Ready pod/forge --timeout=120s >/dev/null

{
  echo "# Cluster"
  echo "\$ kubectl get nodes (name, kubelet, runtime)"
  kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
  echo "\$ kubectl -n kube-system logs ds/kindnet | grep kube-network-policies"
  kubectl -n kube-system logs ds/kindnet | grep -m1 kube-network-policies
  echo

  echo "# 1. Without the policy ($(date '+%F %T'))"
  kubectl -n $NS delete networkpolicy shopping-api-from-gateway --ignore-not-found
  sleep 3
  forge
  echo

  echo "# 2. With the policy ($(date '+%F %T'))"
  kubectl apply -f manifests/80-networkpolicy.yaml
  sleep 3
  forge
  gateway
  echo

  sleep 90
  echo "# 3. Kubelet probes, 90s with the policy ($(date '+%F %T'))"
  probes
} > "$OUT" 2>&1
cat "$OUT"
