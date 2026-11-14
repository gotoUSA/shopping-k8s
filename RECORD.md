# 쇼핑몰 로컬 Kubernetes 배포 기록

쇼핑몰 코드는 고치지 않고, 커밋된 코드를 복사해 로컬 클러스터에 배포한 기록이다. 운영 경험이 아니다.

## 조건

| 항목 | 값 |
|---|---|
| 날짜 | 2026-11-06 |
| 코드 | `gotoUSA/selfhealing` 커밋 `9836d194` (`build/src`에 `git archive`로 복사) |
| 이미지 | `shopping:9836d194`, 1.97GB, 저장소의 `Dockerfile` 그대로 |
| 클러스터 | Docker Desktop Kubernetes(kubeadm), 노드 1개, v1.34.1. 2026-11-11 NetworkPolicy 시험부터 kind v0.33.0, 노드 1개, v1.34.11 |
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
- 2026-11-08 Beat 시작 오류가 로그에 남는지, `celery` logger `propagate`만 바꿔 같은 조건 비교(명령 입력과 출력 확인은 사용자, 시험 파일 작성과 해석 설명은 Claude Code, `tests/beat-logging.yaml`):
  - 쇼핑몰 저장소는 고치지 않았다. `celery.py`가 `DJANGO_SETTINGS_MODULE`을 `setdefault`로 정하므로, ConfigMap으로 넣은 `beat_log_override.py`(원래 설정 전부를 가져온 뒤 `LOGGING["loggers"]["celery"]["propagate"] = True`)를 환경 변수로 지정했다.
  - 두 Pod 모두 `DATABASE_HOST=127.0.0.1`(연결 거부), init 컨테이너 없음, `restartPolicy: Never`.
  - `beat-log-original`(원래 설정): 시작 안내(`celery beat v5.7.0 ... is starting`, `logfile -> [stderr]@%INFO`)까지만 나오고 오류 줄 없음.
  - `beat-log-propagate`: `23:02:40,878 CRITICAL/MainProcess beat raised exception <class 'django.db.utils.OperationalError'>: ... 127.0.0.1, port 5432 failed: Connection refused` 1줄, 이어서 traceback이 조각(`^`, `django.db.utils`, `.` 등)마다 `WARNING/MainProcess` 한 줄씩. 조각나는 이유는 Celery가 stderr를 로그로 바꾸는 동작으로 추정(코드 미확인).
  - 11-07 재현(Claude Code, 포트 오류·timeout)과 달리 이번은 실제 장애와 같은 connection refused다. 1회 시험.
- 2026-11-08 워커 2종과 Beat에 `celery` logger `propagate: True` 적용(명령 입력과 출력 확인은 사용자, 매니페스트 작성·로그 집계는 Claude Code, `manifests/50-workers.yaml`):
  - 방식은 `tests/beat-logging.yaml`과 같다. ConfigMap `celery-log-override`를 세 Deployment에 mount하고 `DJANGO_SETTINGS_MODULE=celery_log_override`로 지정했다. 쇼핑몰 저장소는 고치지 않았다. 적용 23:38, 세 Pod 재시작 0.
  - 적용 전 워커 로그: 작업 안에서 남긴 줄(`미결제 주문 없음` 등)만 있고 Celery 자체 줄은 없었다.
  - 적용 뒤 워커 로그: 시작 때 `Connected to redis://...`, `mingle`, `ready.`. 작업마다 `Task ... received`, `Task ... succeeded in <초>s: <반환값>`. main의 23:40·23:42 작업을 작업 ID별로 세어 `received`·`succeeded` 중복 0. `republish_stalled_orders`가 2분마다 도는 것이 보였다. 이 작업은 대상이 0건이면 스스로 로그를 남기지 않아 이전에는 로그로 확인할 수 없었다.
  - Beat: 작업마다 `Scheduler: Sending due task ...` 1줄. 적용 직전(23:36쯤) 본 Beat 로그 마지막 8줄은 21:59 DB 오류 traceback이었고, 그 사이 5분마다 보낸 작업 줄은 없었다(마지막 8줄만 확인).
  - Redis Pod 삭제(23:45:30, `kubectl delete pod`. 위 21:31 롤링 업데이트와 교체 방식이 달라 같은 조건 비교는 아니다):
    - main: 23:45:32 `WARNING consumer: Connection to broker lost. Trying to re-establish the connection...`, 이어서 `ERROR Error on restarting Gossip: AttributeError(...)`와 긴 traceback 1건, `Cannot connect ... Connection refused` (1/100), 23:46:13 `Error 113 ... No route to host` (2/100), 23:46:17 `Connected`(끊긴 뒤 45초).
    - external: 같은 순서로 23:46:46 `Connected`(74초), `mingle: sync with 1 nodes`.
    - 새 Redis Pod는 23:45:41에 이미 `1/1 Running`이었는데, 두 워커의 두 번째 시도가 각각 약 40초·70초 뒤에 113으로 실패한 이유는 확인하지 않았다.
    - Beat: 23:46:00 `Sending due task republish-stalled-orders`, 오류 줄 없음. main이 그 작업을 다시 연결한 뒤 23:46:18 `received`, 바로 `succeeded`.
    - 세 Pod 재시작 0. 1회 시험.
- 2026-11-09 Redis 대기열이 Pod 교체·갑작스러운 종료 뒤에도 남는지(전 시험 명령 입력은 사용자, 후 시험은 사용자 요청으로 Claude Code가 시각에 맞춰 실행. 시험 순서 설계·스크립트·해석은 Claude Code):
  - 방법: 워커 2종을 0개로 줄여 Beat가 보내는 작업을 Redis에 쌓은 뒤, 센 다음 Redis를 내리고 다시 셌다(`tests/redis-queue-count.sh`). Redis를 내리는 명령은 Beat가 보내지 않는 홀수 분에만 실행했다. 쌓인 작업은 모두 대상 0건인 주기 점검 작업이라, 잃어도 다음 주기에 다시 돈다.
  - 전(Deployment, 볼륨 없음, `kubectl delete pod`): 00:37 7건(`order_processing` 4, `default` 2, `external_api` 1) → 지운 뒤 `order_processing` 1, 전체 키 1. 지운 시각은 Pod 나이로 보아 00:41:30쯤이라 그 사이 00:38·00:40에 보낸 작업이 더 있었고, 지우기 직전 건수는 세지 않았다. 남은 1건은 새 Redis가 뜬 뒤 00:42:00에 보낸 작업으로 추정한다(센 시각 미기록).
  - StatefulSet으로 바꿀 때 옛 Deployment에 있던 6건(00:45:00에 셈)은 옮기지 않아 사라졌다.
  - 후 시험은 `tests/redis-persistence-run.sh`로 실행했고, 출력 전체는 `evidence/redis-persistence.txt`다. 갑자기 죽이기 위해 시험 중에만 `shareProcessNamespace: true`를 켰다(`tests/redis-crash.sh`). 컨테이너 안에서 Redis는 PID 1이라 `kill -9`가 무시되기 때문이다(버리는 Pod로 먼저 확인: PID 1 `/pause`, Redis PID 6, `kill -9` 뒤 `Error`). Redis 7.4.9, 저장 조건 기본값 `save 3600 1 300 100 60 10000`.
  - 후-1(볼륨, appendonly 끔, `delete pod`): 00:49:06 2건 → 지운 뒤 00:49:11 2건. Redis 로그 `RDB age 2 seconds`, `keys loaded: 1`. 정상 종료 때 스냅샷을 저장했다.
  - 후-2(볼륨, appendonly 끔, `kill -9`): 00:53:06 8건, `rdb_changes_since_last_save:6` → 00:53:09 2건. 잃은 6건 = 마지막 스냅샷(00:49 종료 때) 이후 바뀐 6건. Redis 로그 `RDB age 240 seconds`.
  - appendonly 켜기(설정을 바꾸고 Pod 교체): 켜기 전 2건 → 켠 뒤 0건. Redis는 `appendonlydir`의 기록을 읽었는데(`RDB age 486 seconds`, `keys loaded: 0`), 이 기록은 00:45 StatefulSet을 처음 적용했을 때(appendonly 켬, 바로 뒤 `aof-off`) 만들어진 빈 기록이다(`/data/appendonlydir` 파일 시각 15:45 UTC, base 88바이트). appendonly가 켜져 있으면 더 새로운 `dump.rdb`(2건)보다 오래된 이 기록을 썼다. 시험 순서(켬 → 끔 → 켬)가 만든 결과이고, 기록 폴더가 없는 상태에서 처음 켜는 경우는 시험하지 않았다. 실행 중인 서버에서 켤 때는 `CONFIG SET appendonly yes`가 권장 방식으로 알고 있으나 확인하지 않았다.
  - 후-3(볼륨, appendonly 켬, `kill -9`): 00:57:05 6건, `rdb_changes_since_last_save:6` → 00:57:09 6건. 로그 `DB loaded from incr file appendonly.aof.1.incr.aof`. 스냅샷 이후 바뀐 내용을 appendonly 기록에서 되살렸다. `everysec`이라 마지막 1초 안의 쓰기는 잃을 수 있는데, 그 범위는 시험하지 않았다.
  - 정리: `cleanup`(정상 교체) 뒤 6건 유지, Redis가 다시 PID 1. 워커를 1개씩 올리자 대기열 0. main `received` 6·`succeeded` 6(쌓인 5건 + 00:58 새 작업 1건으로 추정), external `received` 1. 시험 동안 Beat 로그에 ERROR·WARNING 없음. 끝난 뒤 `kubectl diff -f manifests/21-redis.yaml` 차이 없음.
  - 각 경우 1회 시험.
- 2026-11-11 레지스트리, 운영 설정, Gateway API(사용자 요청으로 Claude Code가 명령 실행, 결과는 단계마다 사용자 확인. 실행 화면 `evidence/04-registry-gateway.txt`):
  - 레지스트리: `registry:3.1.2` 컨테이너를 `127.0.0.1:5000`에 띄우고 `shopping:9836d194`를 `localhost:5000/shopping:9836d194`로 push(9.8초, digest `sha256:ffe3ef24…` = 로컬 이미지 ID). 로컬에서 레지스트리 이름표를 지운 뒤(`docker rmi`, 원래 이미지는 남음) API·워커·Beat 매니페스트를 그 주소와 `IfNotPresent`로 바꿔 적용 → 이벤트 `Successfully pulled image "localhost:5000/shopping:9836d194" in 2.368s`(Pod 3개), 같은 노드의 나중 Pod는 `already present on machine`. `--restart=always`와 모든 주소에 포트를 여는 실행은 Claude Code 자동 권한 검사에서 거부되어, 자동 재시작 없이 127.0.0.1에만 열었다.
  - 레지스트리가 내려가 있을 때 교체: `docker stop registry`, 이름표를 다시 지우고 API `rollout restart` → 새 Pod `ErrImagePull` → `ImagePullBackOff`(`Head "https://localhost:5000/v2/...": dial tcp [::1]:5000: i/o timeout`), 기존 Pod 2개는 Running 유지. `docker start registry` 뒤 손대지 않았는데 대기 중이던 Pod가 1.79초 만에 이미지를 받아 교체가 끝났다. 1회.
  - 운영 설정: ConfigMap `DJANGO_ENV: production`, `CSRF_TRUSTED_ORIGINS: https://localhost`, Deployment 4개 `rollout restart`. `DEBUG False`, `SECURE_SSL_REDIRECT True`, `debug_toolbar` 없음. 워커·Beat 정상(Beat `Sending due task` → main `received`·`succeeded`).
  - 운영 설정에서 검사가 `/health/`를 실행하지 않았다: Pod 안에서 검사와 같은 요청(`Host: localhost`)을 보내니 `301 https://localhost/health/`. probe는 200~399를 성공으로 보므로 Pod는 Ready였지만, 응답은 Django가 HTTPS로 넘기는 리다이렉트였다. `X-Forwarded-Proto: https`를 붙이면 `200 {"status": "ok"}`. startup·readiness·liveness 세 검사에 이 헤더를 넣은 뒤 로그에 `"GET /health/ HTTP/1.1" 200 16 "-" "kube-probe/1.34"`. 헤더를 넣기 전 검사 로그(301)는 그 Pod가 교체되며 사라져 남기지 못했다.
  - Gateway API: Ingress NGINX는 저장소가 보관 처리됐고 마지막 릴리스가 2026-03-19라, Envoy Gateway v1.9.3(`addons/envoy-gateway-v1.9.3-install.yaml`, `--server-side`)과 `manifests/70-gateway.yaml`(GatewayClass, Gateway의 HTTP 80·HTTPS 443, HTTPRoute `localhost` → `shopping-api:8000`)을 썼다. 인증서는 `openssl`로 만든 자체 서명(`CN=localhost`), Secret `shopping-tls`. Docker Desktop이 Envoy의 LoadBalancer Service를 `localhost:80/443`에 열었다.
  - Windows에서 요청: `http://localhost/health/` → `301 https://localhost/health/`, `https://localhost/health/` → 200, `/api/products/` → 200 JSON, 없는 주소 → 짧은 404(디버그 화면 아님), 응답에 HSTS·`X-Frame-Options: DENY`·`nosniff`, `Host: example.com` → 404(Gateway가 경로 규칙에 없는 호스트를 거부).
  - NetworkPolicy(`manifests/80-networkpolicy.yaml`, API Pod의 8000번에는 이 Gateway의 Envoy Pod만 들어오게): 다른 Pod에서 `X-Forwarded-Proto: https`를 붙여 `shopping-api:8000/health/`로 직접 보낸 요청이 적용 전 200, 적용 뒤에도 200. Docker Desktop의 기본 네트워크에는 NetworkPolicy를 집행하는 플러그인(Calico, Cilium 등)이 없어 정책이 등록만 되고 효과가 없다. 1회.
- 2026-11-11 kind로 옮겨 NetworkPolicy 집행 확인(Claude Code가 설치·명령 실행, 결과는 단계마다 사용자 확인. 실행 화면 `evidence/05-networkpolicy.txt`):
  - 클러스터: Docker Desktop 설정에서 바꾸는 대신 kind CLI v0.33.0(체크섬 확인)으로 `kind/cluster.yaml` 클러스터를 따로 만들었다. 기존 Docker Desktop 클러스터는 지우지 않았다. 노드 이미지는 이전 클러스터·kubectl과 같은 1.34 계열 `kindest/node:v1.34.11`(digest 고정). kindnet 로그에 `"Starting controller" name="kube-network-policies"`, `Policy engine is ready`.
  - 레지스트리: kind 노드 안의 `localhost`는 노드 자신이라 `localhost:5000`이 레지스트리를 가리키지 않는다. 처음 만든 클러스터는 containerd `config_path`가 비어 있어 미러 설정을 읽지 않았다 → `containerdConfigPatches`로 `/etc/containerd/certs.d`를 지정해 다시 만들고, 레지스트리 컨테이너를 `kind` 네트워크에 연결, 노드에 `certs.d/localhost:5000/hosts.toml`(`http://registry:5000`)을 썼다. 노드에서 `crictl pull localhost:5000/shopping:9836d194` 성공. 매니페스트의 이미지 주소는 바꾸지 않았다.
  - Gateway: kind에는 LoadBalancer가 없어 `EnvoyProxy`로 Envoy Service를 NodePort 30080/30443으로 고정하고 Gateway에 연결, kind가 호스트 `127.0.0.1:8080/8443`에 연결. 기존 Docker Desktop 클러스터의 Envoy가 80/443을 쓰고 있어 다른 포트를 골랐다. `https://localhost:8443/health/` 200, `/api/products/` 200 JSON.
  - `deploy.sh`를 빈 클러스터에서 처음 돌리자 TLS 인증서 단계에서 오류 메시지 없이 끝났다. Git Bash에서 `-subj`를 지키려고 켠 `MSYS_NO_PATHCONV=1` 때문에 Windows용 `openssl`이 `/tmp/...` 경로를 못 찾았고, 오류는 `2>/dev/null`이 숨겼다. 이전 클러스터에는 Secret `shopping-tls`가 이미 있어 이 분기가 실행된 적이 없었다. `cygpath -m`으로 바꾼 경로를 넘기게 고친 뒤 빈 클러스터에서 끝까지 실행(1분 47초, Pod 8개 Running/Completed).
  - NetworkPolicy: 같은 네임스페이스의 `celery-main`과 default 네임스페이스의 Pod `forge`(같은 이미지)에서 `shopping-api.shopping.svc:8000/health/`로 직접 요청. 정책 없음: 헤더 없이 301, `X-Forwarded-Proto: https`를 붙이면 200. 정책 적용 3초 뒤: 두 Pod 모두 헤더와 상관없이 5초 시간 초과. 같은 때 Gateway 경유 `https://localhost:8443/health/`·`/api/products/` 200. 정책을 켠 채 90초 동안 API Pod 2개 Ready, 재시작 0, kubelet 검사(노드 주소 `10.244.0.1`에서 옴) Pod마다 27건 모두 200. 3회(1회는 명령을 하나씩, 2·3회는 `tests/networkpolicy-forge.sh`, 결과 같음). 이후 `deploy.sh`가 정책을 함께 적용한다.
  - 포트를 8080/8443으로 옮기면서 `http://localhost:8080/health/` → `301 https://localhost:8080/health/`가 됐다. Django가 받은 Host의 포트를 그대로 두고 https로만 바꾸기 때문이고, 8080은 HTTP 포트라 이 주소는 열리지 않는다. 80/443이던 이전 클러스터에서는 맞았다. 고치지 않았다.
- 2026-11-14 Helm 차트로 옮기기(Claude Code가 차트 작성·설치·명령 실행. 실행 화면 `evidence/06-helm.txt`):
  - Helm v4.3.1(체크섬 확인, `~/bin`). 하루 전에 나온 v4.3.2는 쓰지 않았다.
  - 차트 `chart/`: `helm create` 뒤 기본 템플릿을 지우고 `manifests/`의 9개 파일을 `templates/`로 옮겼다. 바꾼 것은 이미지 주소(`shopping.image`), 네임스페이스(`.Release.Namespace`), HPA 최소·최대·CPU 목표 세 값뿐이다. Namespace는 차트에서 빼고, Secret 2개는 차트에 넣지 않았다(차트에서 만들면 값이 Helm 릴리스 기록에 같이 저장된다. `deploy.sh`가 만든다).
  - migrate Job은 hook(`post-install,pre-upgrade`, `before-hook-creation`)으로 바꿨다. Job의 Pod 템플릿은 바꿀 수 없어 이미지만 바꿔 apply하면 실패하고, upgrade 때는 새 이미지의 Deployment보다 마이그레이션이 먼저 돌아야 한다.
  - `helm template` 출력과 `manifests/`를 객체별로 비교(`tests/helm-template-diff.py`): 18개 중 17개 같음, 다른 1개는 migrate Job의 hook 주석. `--set image.tag=mytest --set api.autoscaling.maxReplicas=4`로 바꾸면 이미지 줄 6개와 `maxReplicas`만 바뀐다.
  - 넘겨받기 1차(revision 1, failed): `helm install --take-ownership --wait`가 32초 만에 실패. NetworkPolicy `.spec.ingress`, StatefulSet 2개 `.spec.volumeClaimTemplates`, Gateway `certificateRefs`, HTTPRoute `parentRefs`·`rules`가 `kubectl-client-side-apply` 소유라 충돌. Helm 4는 server-side apply가 기본이다. 충돌한 리스트를 살아 있는 객체에서 보면 모두 API 서버가 채운 기본값(`volumeMode: Filesystem`, `kind: Secret`, `protocol: TCP`, `weight: 1`, 경로 `/`)이 들어 있고, 차트가 보내는 값에는 없다. 충돌 없던 객체는 이미 Helm 주석이 붙어 있어 `helm uninstall`은 쓰지 않았다(넘겨받은 API·워커가 지워진다).
  - 넘겨받기 2차(revision 2): `helm upgrade --take-ownership --force-conflicts --wait`(먼저 `--dry-run=server`). 넘겨받기 전후 Deployment·StatefulSet·HPA·NetworkPolicy·Gateway·HTTPRoute·EnvoyProxy의 `metadata.generation`이 모두 같고, Pod 재시작 없음. migrate hook이 kubectl로 만든 옛 Job을 지우고 새로 돌아 `No migrations to apply.`, `django_migrations` 110행 그대로, `https://localhost:8443/health/` 200.
  - 이미지 교체 1차(revision 3, failed): `--set image.tag=mytest`(11-08 같은 코드로 다시 빌드한 이미지, 레지스트리에 push). Deployment 4개의 `image`가 `kubectl-client-side-apply`와 충돌. revision 2에서는 값이 같아 Helm이 공동 소유자가 됐을 뿐 kubectl 소유가 남아 있었다. 이때 pre-upgrade hook인 migrate Job은 `mytest`로 이미 실행된 뒤였다. upgrade가 실패해도 마이그레이션은 적용될 수 있다.
  - 이미지 교체 2차(revision 4): `--force-conflicts`를 붙여 1분 8초에 끝. Deployment 4개 `mytest`, Gateway 경유 200. 이후에도 `shopping-api`의 managedFields에 `kubectl-client-side-apply`가 남아 있어, 차트에서 다른 필드를 바꾸면 같은 충돌이 다시 날 수 있다(시험하지 않음).
  - 되돌리기(revision 5): `helm rollback shopping 2 --wait` 40초. 새 revision 5(`Rollback to 2`)가 생기고 기록은 지워지지 않는다. API는 옛 ReplicaSet `69896b69b7`로 돌아갔다(Pod 템플릿이 같아 다시 씀). migrate Job은 `mytest` 그대로였다. rollback에서는 `pre-upgrade` hook이 돌지 않으므로 DB 스키마는 되돌아가지 않는다. `helm history`의 APP VERSION은 revision 4에서도 `9836d194`로, 실제 이미지가 아니라 Chart.yaml 값이다. `helm get values --revision 4`에는 `image.tag: mytest`가 남아 있다.
  - 공개 차트: metrics-server 공식 차트 3.14.0(앱 0.9.0)을 `image.tag=v0.9.1`, `args={--kubelet-insecure-tls}`로 렌더링하니 이미지·인자는 기존 `addons/metrics-server-v0.9.1.yaml`과 같고, Deployment selector가 `k8s-app`에서 `app.kubernetes.io/name`·`instance`로 달랐다. selector는 바꿀 수 없어 넘겨받기 대신 `kubectl delete -f addons/...` 뒤 `helm install`(23초). 지운 지 31초 뒤 `kubectl top` 응답, HPA `cpu: 1%/50%`. 그 사이 HPA 이벤트에 `FailedGetResourceMetric`(metrics API 없음) 경고가 15초 간격으로 2번. HPA는 재시작·rollback 때 CPU가 튀어 6개로 늘어난 뒤 `ScaleDownStabilized`로 6개를 유지하고 있었다(줄어드는 것까지는 보지 않음).
  - 각 1회.
- 2026-11-14 `deploy.sh`를 Helm으로 바꾸고 빈 클러스터에서 실행(Claude Code 실행. kind 클러스터를 지우고 다시 만들어 이전 DB·Redis 시험 데이터는 지움. 실행 화면 `evidence/06-helm.txt` 뒷부분):
  - 바꾼 것: Namespace는 `kubectl create namespace`(Secret을 차트보다 먼저 넣으려고), Secret·TLS·레지스트리 단계는 그대로, Envoy Gateway 설치(차트의 Gateway 종류를 추가하므로 먼저), metrics-server는 공식 차트 `helm upgrade --install --repo ... --version 3.14.0`, 앱은 `helm upgrade --install shopping chart`. 같은 명령이 처음엔 install, 다음부턴 upgrade다.
  - 1차(`--wait`): exit 0, 3분 55초. Beat 재시작 1번. 이전 로그 `relation "django_celery_beat_crontabschedule" does not exist`. migrate Job은 post-install hook이라 `--wait`가 다른 Pod를 다 기다린 뒤에 돌고, 그 전에 Beat가 테이블 없는 DB로 시작했다. 예전 `deploy.sh`는 마이그레이션을 끝낸 뒤 Beat를 올려서 없던 문제다. pre-install hook은 DB가 같은 차트에 있어 그 시점에 DB가 없으므로 쓸 수 없다.
  - 2차: Beat init 컨테이너에 `until python manage.py migrate --check`(적용 안 된 마이그레이션이 있으면 1) 대기를 더했다. 10분 시간 초과로 실패(`resource Deployment/shopping/celery-beat not ready`). `--wait`는 post-install hook 전에 모든 Pod가 Ready가 되길 기다리고, Beat는 그 hook(마이그레이션)을 기다려 서로 기다렸다. Beat 로그 `waiting for migrations` 반복, migrate Job은 만들어지지 않음.
  - 3차: `--wait=hookOnly`(Helm 4에서 플래그를 안 줄 때 기본값. 리소스를 만든 뒤 hook만 기다림) + migrate Job에 DB 대기 init 컨테이너 + Helm 뒤에 `kubectl rollout status`로 Deployment 4개·StatefulSet 2개 확인. exit 0, 4분 17초, 모든 Pod 재시작 0. migrate Job의 DB 대기 `no response` 25줄 뒤 마이그레이션 적용, Beat는 `waiting for migrations` 4번 뒤 Job 완료와 같은 초(10:42:39)에 시작. Gateway `/health/`·`/api/products/` 200, `kubectl top` 응답, HPA 2개, `celery-main`에서 API로 직접 보낸 위조 요청 5초 시간 초과(NetworkPolicy 집행).
  - 같은 `deploy.sh`를 다시 실행: upgrade(revision 2) 17초, pre-upgrade migrate `No migrations to apply.`, Pod 교체 없음.
  - `tests/helm-template-diff.py`: 18개 중 16개 같음. 다른 2개 = migrate Job(hook 주석, DB 대기 init), Beat init(마이그레이션 대기, `shopping-secret` 추가). `manifests/`는 Helm 전 판으로 남기고 배포에 쓰지 않는다.
  - 이미지를 바꾸는 upgrade와 rollback은 이 새 `deploy.sh`·차트로는 다시 하지 않았다(앞 항목의 시험은 init 변경 전 차트).

## 돌려 보지 않은 것

- 주문·결제 같은 실제 작업이 워커까지 처리되는지
- 재시작 원인이 startup이 아닌 liveness 실패인 첫 재시작의 Event 확인(이벤트 집계 범위 밖)

## 나온 것

- `/api/schema/` 생성 중 로그에 `AttributeError: 'AnonymousUser' object has no attribute 'wishlist_products'`(`wishlist_service.py` `get_list`). 응답은 200이다. 쇼핑몰 코드 동결이라 기록만 한다.
- `[SelfHealing] Package not installed, signal hooks disabled`: 이 이미지에는 라이브러리가 설치되지 않았다.
