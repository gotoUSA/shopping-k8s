#!/usr/bin/env bash
# Helpers for the Redis restart/crash test (RECORD.md, 2026-11-09).
#
# Inside a container redis-server is PID 1, and the kernel ignores SIGKILL
# sent to PID 1 from inside its own namespace. shareProcessNamespace makes
# the pod's pause process PID 1, so `kill -9` really kills Redis.
#
#   aof-off  share the process namespace and turn AOF off (volume only)
#   aof-on   turn AOF back on (keeps the shared namespace)
#   kill     kill -9 redis-server (sudden stop, no snapshot on the way out)
#   cleanup  remove the shared namespace; the manifest is back as committed
set -euo pipefail
k() { kubectl -n shopping "$@"; }
case "${1:-}" in
  aof-off)
    k patch statefulset redis --type=json -p '[
      {"op":"add","path":"/spec/template/spec/shareProcessNamespace","value":true},
      {"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--appendonly","no"]}]'
    k rollout status statefulset/redis --timeout=120s ;;
  aof-on)
    k patch statefulset redis --type=json -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--appendonly","yes","--appendfsync","everysec"]}]'
    k rollout status statefulset/redis --timeout=120s ;;
  kill)
    k exec redis-0 -- sh -c 'echo "killing redis-server pid $(pidof redis-server)"; kill -9 $(pidof redis-server)' ;;
  cleanup)
    k patch statefulset redis --type=json -p '[
      {"op":"remove","path":"/spec/template/spec/shareProcessNamespace"}]'
    k rollout status statefulset/redis --timeout=120s ;;
  *)
    echo "usage: $0 aof-off|aof-on|kill|cleanup" >&2; exit 1 ;;
esac
