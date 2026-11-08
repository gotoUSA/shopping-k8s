# 쇼핑몰 로컬 Kubernetes 배포 기록

쇼핑몰 코드는 고치지 않고, 커밋된 코드를 복사해 로컬 클러스터에 배포한 기록이다. 운영 경험이 아니다.

## 조건

| 항목 | 값 |
|---|---|
| 날짜 | 2026-11-06 |
| 코드 | `gotoUSA/selfhealing` 커밋 `9836d194` (`build/src`에 `git archive`로 복사) |
| 이미지 | `shopping:9836d194`, 1.97GB, 저장소의 `Dockerfile` 그대로 |
| 클러스터 | Docker Desktop Kubernetes, 노드 1개, v1.34.1 |
| 올린 것 | PostgreSQL, Redis, 마이그레이션 Job, API, Celery 워커 2종, Beat |
| 실행 | 매니페스트 작성과 명령 실행은 Claude Code가 했다. 범위 판단은 사용자와 함께 했다. |

## Compose와 다르게 한 것

| Compose | 여기 | 이유 |
|---|---|---|
| `web` 시작 때 `migrate` | Job 1회 | API를 여러 개로 늘리면 동시에 실행될 수 있어서 |
| 소스 폴더 볼륨 연결 | 이미지 안의 코드 | 클러스터로 옮길 수 없고, 이미지만으로 실행되는지 보려고 |
| 장애 주입 설정 켬(`PHASE2_CHAOS_MODE` 등) | 넣지 않음 | 일부러 장애를 내는 설정이라서 |
| `.env` 사용 | ConfigMap, Secret | 비밀값은 `deploy.sh`가 만들어 클러스터에만 둔다 |
| 워커 동시 실행 8 | 2 | PC 한 대라서 |
| OTEL, Tempo, Mimir, Loki, Flower | 올리지 않음 | 이번 범위 밖 |

- `.dockerignore`에 `.env`가 없다. 저장소 폴더에서 바로 빌드하면 `.env`가 이미지에 들어간다. 여기서는 `git archive` 복사본으로 빌드해 피했다. 이미지 안에 `.env`가 없는 것을 확인했다. 2026-11-07 사용자 결정(동결의 보안 예외)으로 쇼핑몰 `.dockerignore`에 `.env`를 추가했다. 이미지를 외부 레지스트리에 올린 적은 사용자 기억으로는 없다.
- probe의 `Host: localhost`는 미리 넣었다. 넣지 않았을 때 실패하는지는 돌려 보지 않았다.

## 확인한 것 (2026-11-06)

- Pod 7개 정상: 6개 Running(재시작 0), 마이그레이션 Job Completed
- Service를 거친 요청: `/health/` 200, `/api/products/` 200(`count: 0`, DB 조회), `/api/schema/` 200
- `celery inspect ping`: main, external 워커 2개 응답
- 쇼핑몰 저장소 변경 없음

## 사용자가 직접 돌린 시험

- 2026-11-06 Pod 복구: `kubectl delete pod`로 API Pod `...-qxxql`을 지운 뒤 조회하니 새 Pod `...-c8xcd`가 Running, 재시작 0, 나이 21초. 복구 뒤 API 요청은 돌려 보지 않았다.
- 2026-11-06 API 3개로 늘리기: `kubectl scale --replicas=3` 뒤 3개 모두 Ready. 클러스터 안 임시 Pod에서 Service로 `/api/products/` 30번 요청, 모두 200. Pod별 수신 = `c8xcd` 12, `fqj7f` 5, `zvf9m` 13(로그 집계는 Claude Code). 이 `scale`은 클러스터 값만 바꿨고 `manifests/40-api.yaml`은 그대로 `replicas: 1`이다.
- 2026-11-07 자정 무렵 PostgreSQL 내리기(`/health/` probe 그대로): `postgres` 0개로 내린 뒤 API Pod 3개 모두 `1/1`, 재시작 0. `/api/products/` 5번 모두 500(로그 집계 `c8xcd` 2, `fqj7f` 3). 터미널에는 attach가 늦어 3줄만 보였다. 로그 오류 = `OperationalError ... port 5432 failed: Connection refused`.
- 같은 시험에서 나온 문제: `celery-beat`이 Exit Code 1로 재시작을 반복해 `CrashLoopBackOff`(재시작 3회). 워커 2종은 Running. PostgreSQL을 다시 올린 뒤 00:10:27에 시작한 Beat은 Running으로 돌아왔다(재시작 7회). DB가 내려간 동안 죽은 컨테이너는 00:05:11에 시작해 3초 만에 끝났고, 로그에 오류 메시지가 없었다.
- Beat 오류가 로그에 없는 원인(사용자 질문에서 시작, 조사와 실행은 Claude Code): 잘못된 DB 포트를 준 임시 Pod로 재현했다. 종료 코드 1이고 stdout, stderr, `logs/payment.log`에 오류가 없었다. 프로세스 안에서 잡은 예외는 `django.db.utils.OperationalError`(`setup_schedule`)였다. 이때 logger 상태는 `celery` handlers 없음·`propagate=False`, root에만 stderr handler. `myproject/settings/components/logging.py`의 `"celery"`가 `propagate: False`다. 임시 Pod에서 `celery` logger의 `propagate`만 True로 바꾸니 `CRITICAL beat raised exception ... OperationalError`가 stderr로 나왔다. 재현은 포트 오류(timeout)라 실제 장애의 connection refused와 조건이 다르다. handler를 비우는 주체가 Celery 설정 코드인지는 그 코드를 읽어 확인하지 않았다.
- 워커 로그에도 `celery.*` logger 메시지(`Connected to`, `ready.`)가 없었다. 작업 로그(`ForkPoolWorker`)는 나온다. 쇼핑몰 코드 동결이라 저장소는 고치지 않고 기록만 한다.
- Beat이 보낸 주기 작업(`expire_unpaid_orders` 등)을 `celery-main`이 처리한 로그를 봤다.
- DB를 다시 올린 뒤 API 요청 1번: 200(실행은 Claude Code).
- 2026-11-07 readiness를 `pg_isready`로 바꾼 뒤 PostgreSQL 내리기(`manifests/patch-readiness-db.yaml`, 쇼핑몰 코드 변경 없음, liveness는 `/health/` 유지): API Pod 3개 모두 `0/1`, Running, 재시작 0. EndpointSlice에 IP 3개가 남지만 모두 `ready=false`, `get endpoints`는 빈칸. `/api/products/` 5번 모두 `000`(HTTP 응답 없음). 사용자 예측은 `0/1`, 재시작 0, 200이었고 요청 결과만 달랐다.
- 이 시험의 기록 위치: Kubernetes Event에 `Readiness probe failed: postgres:5432 - no response`가 Pod마다 남았다. API Pod 앱 로그에는 DB 오류가 0건이다. 앞선 `/health/` 시험에서는 요청이 API까지 가서 앱 로그에 `OperationalError`가 남았다.
- 2026-11-07 무중단 교체 1차(요청 대상 `/api/products/`, 0.1초 간격): 사용자 집계 시점 `200` 100, `429` 510, `000` 8. 조금 뒤 Claude Code 집계 705건은 `200` 100, `429` 597, `000` 8. 처음 200 100건 뒤 익명 제한(`anon_global` 100/hour, `local.py`)에 걸렸고, 첫 429(00:38:42)가 첫 새 Pod 시작(00:38:44)보다 빠르다. 그래서 교체 중 성공 수는 재지 못했고 이 시험은 무중단 판정에 쓸 수 없다. 시험 설계를 잘못한 것은 Claude Code다. `000` 8건은 00:38:55~00:39:14에 나와 교체 시간대와 겹치지만, 원인은 확인하지 못했다.
- 2026-11-07 무중단 교체 2차(요청 대상 `/health/`, 0.1초 간격, 복사본 이미지에서 원본 이미지로): 교체 전 `200` 737건 확인 후 교체. 교체 직후 사용자 집계 `200 0` 1271, `000 7` 7. 실패는 모두 curl 종료 코드 7(연결 실패)이고 재시도 없이 집계했다. 실패 시각 00:43:06~07, 00:43:13, 00:43:20으로 세 묶음이며, Pod 종료 이벤트 3개와 간격이 맞는다. 첫 실패부터 끝 실패까지 125건 중 7건 실패. 종료 중 Pod로 새 연결이 간다는 원인은 preStop 시험 전까지 가설이다. 시각 대조는 Claude Code가 했다.
- 2026-11-07 무중단 교체 3차(`manifests/patch-prestop.yaml`: `preStop` 10초, 종료 유예 45초, `/health/`, 0.1초 간격, 같은 이미지 `rollout restart`): 교체 끝 사용자 집계 `200 0` 306. 몇 초 뒤 Claude Code 집계 371건 전부 `200 0`, 실패 0. Pod 종료 이벤트 00:48:28, 35, 41과 그 10초 뒤를 측정 구간(00:48:13~55)이 덮는다. 2차와 3차는 이미지 방향이 다르다. 쇼핑몰 코드 변경 없음.
- 2026-11-07 01:14 무중단 교체 4차(3차와 같은 조건, 실행은 Claude Code, `evidence/02-rolling-update.txt`): 388건 전부 `200 0`, 실패 0. Pod 종료 이벤트 01:14:29, 36, 42와 그 10초 뒤를 측정 구간(01:14:13~58)이 덮는다. preStop 있는 교체 2회 모두 실패 0, preStop 없는 교체는 7건 1회.
- 2026-11-07 `/health/` 수정본 시험(커밋 없는 복사본 `shopping:9836d194-health-db`, `/health/`가 `SELECT 1` 실행, startup·readiness·liveness 모두 이 경로, 실행은 Claude Code): PostgreSQL을 내리고 60초 뒤 API Pod 3개 `0/1`, 재시작 1. 120초 뒤 그대로 재시작 1. 240초 뒤 재시작 2. Event에 Readiness·Startup probe 500과 `Container api failed startup probe, will be restarted`. `/api/products/` 5번 모두 `000 7`. 사용자 예측은 `0/1`, 재시작 늘어남, 500으로 요청 결과만 달랐다. 앱 로그 `OperationalError`는 Pod별 0, 2, 4건이고 재시작으로 앞 로그가 빠졌을 수 있다.
- 시험 뒤 PostgreSQL 복구, 원본 이미지로 복귀. 최종 설정은 `manifests/40-api.yaml`에 preStop을 반영했다(readiness는 `/health/`).
- PostgreSQL을 다시 올린 뒤 API Pod 3개 `1/1`, 재시작 0으로 돌아왔다. Beat은 재시작 13회 후 Running.
- 2026-11-08 빌드·교체·실패·되돌리기(명령 입력과 출력 확인은 사용자, 해석 설명은 Claude Code):
  - Docker Desktop이 꺼져 있어 `kubectl`이 `127.0.0.1:6443` connection refused. Docker Desktop을 켜자 클러스터가 함께 시작됐고, 11-07의 Pod 9개가 같은 이름으로 남아 있었다(API 3개 = 11-06 `scale` 값 유지, Beat 재시작 20회). 다른 Pod의 마지막 재시작이 "17h ago"로 나온 이유는 확인하지 않았다.
  - `build/src`에서 `docker build -t shopping:mytest .`: 11단계 모두 `CACHED`. IMAGE ID는 `9836d194`(`ffe3ef24923c`)와 다른 `bfb108321f09`이고, 레이어 생성 시각은 모두 42시간 전이다. ID 차이의 원인은 확인하지 않았다.
  - `docker history`: `pip install -r requirements-dev.txt`(내용은 `-e ".[dev]"`, 운영·개발 패키지 합계) 862MB, `apt-get install` 498MB, 기본 이미지 약 134MB, 코드 6.43MB. 합계 약 1.5GB와 `DISK USAGE` 1.97GB의 차이는 확인하지 않았다.
  - `kubectl set image deployment/shopping-api api=shopping:mytest`: 새 ReplicaSet `6798f444c6`, Pod 3개가 약 6초 간격으로 교체됐고, `rollout status`에 `1 old replicas are pending termination`(preStop 10초) 뒤 완료. 새 Pod 로그는 `kube-probe/1.34`의 `/health/` 200만 있고, 10초에 3번(readiness 5초, liveness 10초)이다.
  - `set image ... api=shopping:typo`: 명령은 `image updated`로 받아들여졌고, 새 Pod 1개(17:55:48 시작)만 `ErrImageNeverPull`. 기존 Pod 3개는 Running 유지(기본값 maxSurge 25% → 1, maxUnavailable 25% → 0). `describe` Events: `Scheduled` 성공 뒤 kubelet `Container image "shopping:typo" is not present with pull policy of Never`가 약 6분 동안 26번.
  - `rollout undo`: `mytest` 판으로 돌아갔고, 기존 Pod 3개는 그대로(18m), `typo` Pod만 사라짐.
  - 되돌린 뒤 API Pod 안에서 Service로 `curl -si shopping-api:8000/api/products/`(18:13): `HTTP/1.1 200 OK`, `Server: gunicorn`, 본문 `{"count":0,...}`.
  - 이후 클러스터의 API 이미지는 `shopping:mytest`이고, `manifests/40-api.yaml`은 `shopping:9836d194` 그대로다.
- 2026-11-08 HPA(명령 입력과 출력 확인은 사용자, 해석 설명과 파일 작성은 Claude Code):
  - `kubectl top`: `Metrics API not available`. 클러스터에 metrics-server가 없었다.
  - metrics-server 설치: GitHub 릴리스 주소로 `kubectl apply -f`가 504(v0.7.2, v0.9.1 모두). 같은 시각 Claude Code의 `curl`은 v0.9.1을 200으로 받았다. 받은 파일을 `addons/metrics-server-v0.9.1.yaml`로 저장해 적용, 객체 9개 `created`.
  - metrics-server `0/1 Running`. 로그 = `x509: cannot validate certificate for 192.168.65.3 because it doesn't contain any IP SANs`(kubelet 인증서), 이어서 readiness `no metrics to serve`. 파일에 `--kubelet-insecure-tls`(로컬 전용 주석)를 넣고 다시 적용 → Deployment만 `configured`, 나머지 8개 `unchanged`.
  - 한가할 때 `kubectl top`: API CPU 4~6m, 메모리 235~247Mi. 워커 232Mi, Beat 144Mi, PostgreSQL 60Mi, Redis 33Mi.
  - `set resources`로 API에 requests(CPU 100m, 메모리 256Mi), limits(메모리 512Mi). CPU limits는 넣지 않음. 명령 2번 → 중간 ReplicaSet `dcb6dc774`가 2개까지 뜨다 0으로, 최종 `b446fb5d` 3개. Deployment revision 14. API Pod QoS `BestEffort` → `Burstable`. PostgreSQL, Redis, 워커, Beat은 requests가 없어 `BestEffort` 그대로다.
  - `kubectl autoscale ... --cpu-percent=50 --min=2 --max=6`(19:28:28 생성, `--cpu-percent`는 deprecated 경고, 같은 동작). 만든 직후 `<unknown>/50%`, REPLICAS 0. 이후 Events 3 → 2(`All metrics below target`, 생성 약 6분 뒤).
  - 부하: `load/hpa-load.yaml`(busybox 반복문 4개, Service의 `/health/`). `kubectl top`: API 6개 Pod당 183~211m, 메모리 223~235Mi, 부하 Pod 1,942m. HPA `187%/50%`, Events 2 → 4, 1분쯤 뒤 4 → 6, Conditions `ScalingLimited True TooManyReplicas`.
  - 부하 Pod 삭제 뒤 약 1분: `6%/50%`, REPLICAS 6. Events 6 → 2 한 줄(중간 개수 없음), 4 → 6 이벤트 약 7분 뒤. 삭제 시각을 따로 적지 않아 5분 창과의 정확한 대조는 하지 않았다. 이후 `ScalingLimited True TooFewReplicas`.
  - 같은 PC에서 부하 Pod가 CPU 약 2코어를 써서, 처리량은 판단하지 않는다. 늘고 주는 동작만 확인했다.
  - 클러스터와 파일 맞춤: `40-api.yaml`에 resources 추가, `replicas` 삭제(HPA가 정함), `manifests/60-api-hpa.yaml` 추가, `deploy.sh`에 metrics-server와 HPA 적용 추가. 이 파일들로 새로 배포해 보지는 않았다.
- 2026-11-08 Beat DB 대기 init 컨테이너(명령 입력과 출력 확인은 사용자, 매니페스트 작성과 해석 설명은 Claude Code):
  - 고치기 전: `postgres` 0개로 내리고 Beat Pod 삭제. 새 Pod `...-nc4vt`가 5분 38초 동안 재시작 5번, `CrashLoopBackOff`.
  - `manifests/50-workers.yaml` Beat에 `initContainers` `wait-for-db` 추가(쇼핑몰 이미지, `pg_isready -h $DATABASE_HOST -p $DATABASE_PORT`가 될 때까지 2초 간격). 서버 dry-run과 적용 결과 모두 워커 2종 `unchanged`, Beat만 `configured`.
  - DB를 내린 채 적용: 새 Pod `...-fc52k`가 116초 동안 `Init:0/1`, 재시작 0. `logs -c wait-for-db` = `postgres:5432 - no response`, `waiting for db` 반복.
  - `postgres` 1개로 올린 뒤: `1/1 Running`, 재시작 0(5분 35초 시점). init 로그 마지막 줄 `postgres:5432 - accepting connections`. Beat 로그 `21:19:13 DatabaseScheduler: Schedule changed.`
  - 1회 시험이다. init 컨테이너는 시작할 때만 기다리고, 실행 중 DB가 끊기는 경우는 다루지 않는다.
- 2026-11-08 나머지 Pod에 requests/limits(명령 입력과 출력 확인은 사용자, 매니페스트 작성·로그 집계·설정 파일 확인은 Claude Code):
  - 값(한가할 때 측정값 기준): PostgreSQL requests = limits = CPU 500m, 메모리 512Mi(Guaranteed). Redis 50m/64Mi, 메모리 limit 256Mi. 워커 2종 100m/256Mi, 512Mi. Beat 50m/192Mi, 384Mi. 적용 전 서버 dry-run.
  - 적용 순서: `50-workers.yaml`(워커·Beat) → `21-redis.yaml` → `20-postgres.yaml`. 결과 QoS: PostgreSQL `Guaranteed`, 나머지 `Burstable`(끝난 `migrate` Pod만 `BestEffort`). 모든 Pod 재시작 0.
  - Redis 교체(롤링 업데이트): 워커 로그 21:31:09에 `CPendingDeprecationWarning`(연결이 끊기면 `acks_late` 작업은 확인할 수 없어 다시 전달된다는 내용), 이후 21:35·21:40 주기 작업 처리. 다시 연결했다는 줄은 없다(11-07 `celery` logger `propagate: False`와 같은 이유로 추정).
  - Redis 매니페스트에 볼륨이 없어, Pod가 바뀌면 대기열과 처리 중 작업이 함께 사라진다. 쇼핑몰 작업 다수가 `acks_late=True`(build/src에서 확인)지만, 이는 워커가 죽는 경우를 위한 것이라 브로커 데이터 손실은 막지 못한다. 이번에는 21:31~21:35 사이 예정 작업이 없어 잃은 작업은 없었고, 일부러 시험하지 않았다. 롤링 업데이트 중 옛·새 Redis가 잠깐 함께 Service 뒤에 있는 점도 같은 문제다.
  - PostgreSQL 교체: 새 `postgres-0` 시작 21:59:06. Beat 로그 21:59:10 `ERROR ... Database gave error: OperationalError(... Connection refused)` 1건, Beat 재시작 0. 워커는 22:00부터 5분마다 주기 작업을 계속 처리. API는 재시작 0(DB를 쓰는 요청의 그 사이 결과는 재지 않음). 교체 뒤 `/api/products/` 200(테이블 유지, 상품 0개라 행 유지는 확인 못 함).
  - 같은 요청 응답에 `Server-Timing`(Debug Toolbar 패널, SQL 5.7ms, 전체 510ms)과 `djdt-request-id` 헤더. ConfigMap `DJANGO_ENV: local`(11-06 배포 때 Claude Code가 정함) → `local.py`의 `DEBUG = True`와 Debug Toolbar. 툴바는 `INTERNAL_IPS`(Pod IP 끝자리를 `.1`로 바꾼 주소)일 때만 켜지는데, 요청이 Service를 거쳐 보낸 Pod 자신에게 돌아가 출발지가 `10.1.0.1`이 됐다고 추정한다(확인 안 함). 18:13 응답에는 이 헤더가 없었다. 로컬이라 외부 노출은 없다.

## 돌려 보지 않은 것

- 주문·결제 같은 실제 작업이 워커까지 처리되는지
- 재시작 원인이 startup이 아닌 liveness 실패인 첫 재시작의 Event 확인(이벤트 집계 범위 밖)

## 나온 것

- `/api/schema/` 생성 중 로그에 `AttributeError: 'AnonymousUser' object has no attribute 'wishlist_products'`(`wishlist_service.py` `get_list`). 응답은 200이다. 쇼핑몰 코드 동결이라 기록만 한다.
- `[SelfHealing] Package not installed, signal hooks disabled`: 이 이미지에는 라이브러리가 설치되지 않았다.
