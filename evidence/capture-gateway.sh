#!/usr/bin/env bash
# Capture the registry, production settings and Gateway checks (2026-11-11)
# into evidence/04-registry-gateway.txt. Read-only: it changes nothing.
set -uo pipefail
cd "$(dirname "$0")"
NS=shopping
run() { echo "\$ $*"; "$@" 2>&1; echo; }

{
  echo "# 1. Image comes from the local registry"
  run curl -s http://localhost:5000/v2/shopping/tags/list
  echo
  run kubectl -n $NS get deployments -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,PULL:.spec.template.spec.containers[0].imagePullPolicy

  echo "# 2. Production settings"
  echo "\$ kubectl -n $NS exec deploy/shopping-api -- python manage.py shell -c '...'"
  kubectl -n $NS exec deploy/shopping-api -- python manage.py shell -c \
    "from django.conf import settings as s; print('DEBUG', s.DEBUG, '| SECURE_SSL_REDIRECT', s.SECURE_SSL_REDIRECT, '| debug_toolbar', 'debug_toolbar' in s.INSTALLED_APPS)" 2>&1 | tail -1
  echo
  echo "# 3. What a probe gets: without X-Forwarded-Proto it is a 301, which a probe counts as success"
  echo "\$ kubectl -n $NS exec deploy/shopping-api -- python -c '<GET /health/ on 127.0.0.1:8000>'"
  kubectl -n $NS exec deploy/shopping-api -- python -c "
import http.client
for hdr in ({'Host': 'localhost'}, {'Host': 'localhost', 'X-Forwarded-Proto': 'https'}):
    c = http.client.HTTPConnection('127.0.0.1', 8000, timeout=5)
    c.request('GET', '/health/', headers=hdr)
    r = c.getresponse()
    print(sorted(hdr), '->', r.status, r.getheader('Location') or r.read().decode())
" 2>&1
  echo
  echo "\$ kubectl -n $NS logs deploy/shopping-api | grep kube-probe | tail -2"
  kubectl -n $NS logs deploy/shopping-api --tail=200 2>&1 | grep kube-probe | tail -2
  echo

  echo "# 4. Gateway API (Envoy Gateway v1.9.3)"
  run kubectl -n $NS get gateway,httproute
  run kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=shopping
  echo "\$ curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' http://localhost/health/"
  curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" http://localhost/health/
  echo "\$ curl -sk https://localhost/health/"
  curl -sk -w "  [%{http_code}]\n" https://localhost/health/
  echo "\$ curl -sk -o /dev/null -w '%{http_code} %{content_type}' https://localhost/api/products/"
  curl -sk -o /dev/null -w "%{http_code} %{content_type}\n" https://localhost/api/products/
  echo "\$ curl -sk -o /dev/null -w '%{http_code}' https://localhost/no-such-page/"
  curl -sk -o /dev/null -w "%{http_code}\n" https://localhost/no-such-page/
  echo "\$ curl -skI https://localhost/health/ | grep -i -E 'strict-transport|x-frame|x-content-type'"
  curl -skI https://localhost/health/ | grep -i -E "strict-transport|x-frame|x-content-type"
  echo "\$ curl -sk -o /dev/null -w '%{http_code}' -H 'Host: example.com' https://localhost/health/"
  curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: example.com" https://localhost/health/
} > 04-registry-gateway.txt
echo done
