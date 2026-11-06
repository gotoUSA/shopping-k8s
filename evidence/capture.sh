#!/usr/bin/env bash
# Capture real command output from the local cluster into evidence/*.txt.
set -uo pipefail
cd "$(dirname "$0")"
NS=shopping
run() { echo "\$ $*"; "$@" 2>&1; echo; }

{
  run kubectl get nodes
  run kubectl -n $NS get deployments,statefulsets,jobs,services
  run kubectl -n $NS get pods
} > 01-cluster-state.txt

{
  echo "\$ kubectl -n $NS run load ... (request /health/ every 0.1s, print http_code and curl exit code)"
  kubectl -n $NS delete pod load --ignore-not-found >/dev/null 2>&1
  kubectl -n $NS run load --restart=Never --image=shopping:9836d194 --image-pull-policy=Never --command -- \
    sh -c 'while true; do curl -s -o /dev/null -w "%{http_code} %{exitcode}\n" --max-time 5 http://shopping-api:8000/health/; sleep 0.1; done' 2>&1
  kubectl -n $NS wait --for=condition=Ready pod/load --timeout=60s >/dev/null 2>&1
  sleep 8
  echo
  echo "\$ kubectl -n $NS logs load | sort | uniq -c   # before rollout"
  kubectl -n $NS logs load | sort | uniq -c
  echo
  run kubectl -n $NS rollout restart deployment/shopping-api
  run kubectl -n $NS rollout status deployment/shopping-api --timeout=300s
  sleep 15
  echo "\$ kubectl -n $NS logs load | sort | uniq -c   # after rollout"
  kubectl -n $NS logs load | sort | uniq -c
  echo
  run kubectl -n $NS get pods -l app=shopping-api
  kubectl -n $NS logs load --timestamps > load-timestamps.txt 2>/dev/null
  kubectl -n $NS delete pod load >/dev/null 2>&1
} > 02-rolling-update.txt

{
  echo "\$ kubectl -n $NS logs deploy/shopping-api --tail=6"
  kubectl -n $NS logs deploy/shopping-api --tail=6 2>&1 | cut -c1-140
  echo
  echo "\$ kubectl -n $NS logs deploy/celery-main --tail=4"
  kubectl -n $NS logs deploy/celery-main --tail=4 2>&1 | cut -c1-140
  echo
  run kubectl -n $NS exec deploy/celery-main -- celery -A myproject inspect ping
} > 03-logs.txt
echo done
