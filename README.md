# shopping-k8s

Django 쇼핑몰 API([gotoUSA/selfhealing](https://github.com/gotoUSA/selfhealing))를 로컬 Kubernetes 클러스터에 배포하고, 장애와 버전 교체를 시험한 기록입니다. Kubernetes는 2026년 11월에 처음 사용했습니다. **운영 경험이 아니라 로컬 클러스터 실습입니다.**

매니페스트 작성과 분석에는 Claude Code를 사용했습니다. 실행 주체는 [RECORD.md](RECORD.md)에 시험별로 나눠 적었고, 기록의 "사용자"는 이 저장소 작성자입니다.

## 실행 화면

| 내용 | 이미지 | 원문 |
|---|---|---|
| 클러스터와 Pod 상태 | [PNG](evidence/01-cluster-state.png) | [txt](evidence/01-cluster-state.txt) |
| 요청을 보내며 버전 교체 | [PNG](evidence/02-rolling-update.png) | [txt](evidence/02-rolling-update.txt) |
| API·워커 로그 | [PNG](evidence/03-logs.png) | [txt](evidence/03-logs.txt) |
| 레지스트리, 운영 설정, Gateway | [PNG](evidence/04-registry-gateway.png) | [txt](evidence/04-registry-gateway.txt) |

PNG는 실제 명령 출력을 `evidence/render.py`로 그린 이미지입니다. `evidence/capture.sh`, `evidence/capture-gateway.sh`로 다시 만들 수 있습니다.

## 구성

- 클러스터: Docker Desktop Kubernetes, 노드 1개
- 이미지: 쇼핑몰 저장소의 [Dockerfile](https://github.com/gotoUSA/selfhealing/blob/9836d194/Dockerfile)로 빌드해 로컬 레지스트리(`registry:3.1.2` 컨테이너, `localhost:5000`)에 올리고, 클러스터는 거기서 받음
- 올린 것: PostgreSQL, Redis, 마이그레이션 Job, API(HPA로 2~6개), Celery 워커 2종, Beat 1개, metrics-server, Envoy Gateway(Gateway API, `https://localhost`)
- 설정: 쇼핑몰 운영 설정(`DJANGO_ENV: production`, `DEBUG` 꺼짐, HTTPS 리다이렉트). TLS는 Gateway에서 끝내고 자체 서명 인증서 사용
- 비밀값: `deploy.sh`가 생성해 클러스터 Secret에만 저장

## 재현

```bash
git clone https://github.com/gotoUSA/selfhealing.git build/src
git -C build/src checkout 9836d194
docker build -t shopping:9836d194 build/src
bash deploy.sh
```

## 시험 결과

| 시험 | 결과 |
|---|---|
| API Pod 삭제 | 새 Pod가 뜸 |
| API 3개에 요청 30번 | 3개로 나뉘어 모두 200 |
| 교체, 기본 설정 | 성공 1,271, 연결 실패 7 (1회) |
| 교체, `preStop` 10초 | 성공 371, 388, 실패 0 (2회) |
| DB 장애, `/health/` 원본 | READY `1/1`, 재시작 0, 요청 500 |
| DB 장애, readiness `pg_isready` | READY `0/1`, 재시작 0, 응답 없음 |
| DB 장애, `/health/`에 DB 확인 추가 | READY `0/1`, 재시작 늘어남, 응답 없음 |
| 없는 이미지 이름으로 교체 | 새 Pod `ErrImageNeverPull`, 기존 Pod 3개 유지, `rollout undo`로 복구 |
| HPA(CPU 50%, 2~6개), `/health/` 부하 | 2 → 4 → 6개(최대에 막힘), 부하를 끄고 몇 분 뒤 6 → 2개 (1회) |
| DB를 내린 채 Beat 시작, 기본 설정 | `CrashLoopBackOff`, 5분 38초에 재시작 5번 |
| 같은 조건, DB 대기 init 컨테이너 | `Init:0/1`로 대기, 재시작 0, DB가 돌아오자 바로 시작 (1회) |
| 모든 Pod에 requests/limits | PostgreSQL `Guaranteed`, 나머지 `Burstable`. DB 교체 중 Beat 오류 로그 1건, 재시작 0 |
| DB 연결 거부로 Beat 시작, `celery` logger `propagate`만 다르게 | False: 오류 줄 없음 / True: `CRITICAL ... OperationalError` 1줄 (1회, [tests/beat-logging.yaml](tests/beat-logging.yaml)) |
| 워커·Beat에 `propagate: True` 적용, Redis Pod 삭제 | 작업 `received`·`succeeded`, Beat `Sending due task` 줄이 생김(중복 0). 끊김·재시도·다시 연결 줄이 보이고 45초·74초 뒤 다시 연결, 재시작 0 (1회) |
| Redis 대기열, 볼륨 없음 → `delete pod` | 7건 쌓은 뒤 교체, 옛 작업 0건 |
| 볼륨(StatefulSet), `delete pod` / `kill -9` | 2 → 2건 / 8 → 2건(마지막 스냅샷 이후 6건 잃음) |
| 레지스트리에서 받아 배포 | 이벤트 `Successfully pulled image "localhost:5000/..."` |
| 레지스트리를 내린 채 교체 | 새 Pod `ImagePullBackOff`, 기존 Pod 유지. 레지스트리를 켜자 자동으로 받아 교체 완료 (1회) |
| 운영 설정에서 검사 요청 | 헤더 없이 `301`(검사는 성공으로 봄, `/health/` 실행 안 됨) → `X-Forwarded-Proto: https`를 넣어 200 |
| Gateway로 요청 | HTTP → 301 HTTPS, HTTPS `/health/`·`/api/products/` 200, 다른 호스트 404 |
| 볼륨 + appendonly, `kill -9` | 6 → 6건. 시험 중 appendonly를 끄고 다시 켰을 때 오래된 빈 기록을 읽어 2 → 0건 ([출력](evidence/redis-persistence.txt), 각 1회) |

## 알려진 문제

- 장고가 `X-Forwarded-Proto` 헤더를 믿기 때문에, 클러스터 안에서 API Pod로 직접 이 헤더를 붙여 보내면 HTTPS 요청으로 취급됩니다. Gateway의 Envoy만 API에 들어오게 하는 NetworkPolicy(`manifests/80-networkpolicy.yaml`)를 넣었지만, Docker Desktop 기본 네트워크는 NetworkPolicy를 집행하지 않아 적용 전후 모두 위조 요청이 200이었습니다.
- 인증서는 자체 서명이라 브라우저가 경고합니다.
- Redis는 1개뿐입니다. 볼륨과 appendonly(`everysec`)로 교체·갑작스러운 종료 뒤에도 대기열이 남지만, Redis가 내려가 있는 동안은 작업을 보낼 수 없습니다.

HPA 시험은 부하 Pod와 API가 같은 PC의 CPU를 나눠 써서(부하 Pod 약 2코어), 늘고 주는 동작만 확인했고 처리량은 재지 않았습니다.

## 해 보지 않은 것

클라우드 배포, 실제 트래픽 운영, 외부 레지스트리(Docker Hub, 클라우드), 공인 인증서, 주문·결제 요청을 끝까지 처리하는 시험, 처리량 측정.
