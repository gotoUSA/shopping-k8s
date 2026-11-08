#!/usr/bin/env bash
# Print every list key in Redis with its length (Celery queues are lists).
# Usage: bash tests/redis-queue-count.sh
kubectl -n shopping exec "$(kubectl -n shopping get pod -l app=redis -o name | head -1)" -- sh -c '
for k in $(redis-cli --scan); do
  [ "$(redis-cli type "$k")" = list ] && echo "$k $(redis-cli llen "$k")"
done; echo "keys total: $(redis-cli dbsize)"'
