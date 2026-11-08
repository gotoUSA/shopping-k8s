#!/usr/bin/env bash
# Redis after-test: volume only (graceful, kill -9), AOF enable, volume+AOF (kill -9), cleanup.
# Run on 2026-11-09 by Claude Code at the user's request; output: evidence/redis-persistence.txt.
# The `ls /data` line fails under Git Bash (path conversion); use //data there.
# Destructive actions run only in odd minutes (Beat sends in even minutes).
set -u
cd "$(dirname "$0")/.."
k() { kubectl -n shopping "$@"; }
ts() { date '+%H:%M:%S'; }
say() { echo; echo "=== [$(ts)] $*"; }
count() { echo "[$(ts)] queue count:"; bash tests/redis-queue-count.sh; }
pers() { k exec redis-0 -- sh -c 'redis-cli config get appendonly | tr "\n" " "; echo; redis-cli info persistence | grep -E "^(aof_enabled|rdb_changes_since_last_save|rdb_last_save_time|loading):"' | tr -d '\r'; }
uid() { k get pod redis-0 -o jsonpath='{.metadata.uid}' 2>/dev/null; }
rc() { k get pod redis-0 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null; }
wait_odd() {
  while :; do
    m=$((10#$(date +%M))); s=$((10#$(date +%S)))
    [ $((m % 2)) -eq 1 ] && [ $s -ge 5 ] && [ $s -le 40 ] && return
    sleep 3
  done
}
wait_even_passes() {  # wait until $1 new even minutes have started (+3s)
  local n=$1 last; last=$(date +%H%M)
  while [ "$n" -gt 0 ]; do
    sleep 5
    hm=$(date +%H%M); m=$((10#$(date +%M))); s=$((10#$(date +%S)))
    if [ "$hm" != "$last" ] && [ $((m % 2)) -eq 0 ] && [ $s -ge 3 ]; then n=$((n - 1)); last=$hm; fi
  done
}
wait_ready_after() {  # $1 old uid, $2 old restart count
  for _ in $(seq 1 90); do
    u=$(uid); r=$(rc); rd=$(k get pod redis-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    if [ "$rd" = true ] && { [ "$u" != "$1" ] || [ "${r:-0}" -gt "$2" ]; }; then
      echo "[$(ts)] redis-0 ready (uid ${u:0:8}, restarts $r)"; return
    fi
    sleep 2
  done
  echo "[$(ts)] TIMEOUT waiting for redis-0"
}
accumulate_then() {  # $1 label
  say "$1: accumulating (2 even-minute sends)"
  wait_even_passes 2
  wait_odd
  pers; count
}

say "start"; k get pods -l app=redis; count

say "switch to StatefulSet (odd minute)"
wait_odd
k delete deployment redis
k apply -f manifests/21-redis.yaml
k rollout status statefulset/redis --timeout=180s
bash tests/redis-crash.sh aof-off
k get pods -l app=redis; k get pvc
k exec redis-0 -- sh -c 'ps; redis-cli info server | grep redis_version; redis-cli config get save | tr "\n" " "; echo' | tr -d '\r'
pers; count

# A1: volume only, graceful delete
accumulate_then "A1 volume only, graceful delete"
U=$(uid); R=$(rc); echo "[$(ts)] delete pod redis-0"; k delete pod redis-0
wait_ready_after "$U" "$R"; count; pers
k logs redis-0 --tail=12

# A2: volume only, kill -9
accumulate_then "A2 volume only, kill -9"
U=$(uid); R=$(rc); bash tests/redis-crash.sh kill
wait_ready_after "$U" "$R"; count; pers
echo "--- previous container log tail"; k logs redis-0 --previous --tail=5
echo "--- current container log tail"; k logs redis-0 --tail=12

# Turning AOF on (pod replaced, graceful)
say "AOF on (pod replaced)"
wait_odd
pers; count
bash tests/redis-crash.sh aof-on
k wait --for=condition=Ready pod/redis-0 --timeout=90s
count; pers
k logs redis-0 --tail=15
k exec redis-0 -- ls -la /data /data/appendonlydir 2>&1 | tr -d '\r'

# A3: volume + AOF, kill -9
accumulate_then "A3 volume + AOF, kill -9"
U=$(uid); R=$(rc); bash tests/redis-crash.sh kill
wait_ready_after "$U" "$R"; count; pers
echo "--- current container log tail"; k logs redis-0 --tail=12

say "cleanup (odd minute)"
wait_odd
count
bash tests/redis-crash.sh cleanup
k wait --for=condition=Ready pod/redis-0 --timeout=90s
count
k exec redis-0 -- ps | tr -d '\r'
k scale deploy/celery-main deploy/celery-external --replicas=1
k rollout status deploy/celery-main --timeout=180s
k rollout status deploy/celery-external --timeout=180s
sleep 40
count
echo "--- celery-main received/succeeded since start of workers"
k logs deploy/celery-main | grep -cE "\] received$"
k logs deploy/celery-main | grep -cE "succeeded in"
k logs deploy/celery-external | grep -cE "\] received$"
say "Beat errors during test"
k logs deploy/celery-beat -c beat --since=60m | grep -E "ERROR|CRITICAL|WARNING" | head -20
k get pods
say "done"
