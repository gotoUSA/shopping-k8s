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
| NetworkPolicy 적용 전후 위조 요청 (kind) | [PNG](evidence/05-networkpolicy.png) | [txt](evidence/05-networkpolicy.txt) |
| Helm 차트로 넘겨받기·교체·되돌리기 (kind) | | [txt](evidence/06-helm.txt) |

PNG는 실제 명령 출력을 `evidence/render.py`로 그린 이미지입니다. `evidence/capture.sh`, `evidence/capture-gateway.sh`, `tests/networkpolicy-forge.sh`로 다시 만들 수 있습니다. 01~04는 Docker Desktop 클러스터(`https://localhost`)에서, 05는 kind 클러스터에서 찍었습니다.

## 구성

- 클러스터: kind v0.33.0, 노드 1개, Kubernetes v1.34.11([kind/cluster.yaml](kind/cluster.yaml)). 2026-11-11 이전 시험은 Docker Desktop Kubernetes(kubeadm, v1.34.1)에서 했고, 그 네트워크가 NetworkPolicy를 집행하지 않아 kind(kindnet이 집행)로 옮겼습니다.
- 이미지: 쇼핑몰 저장소의 [Dockerfile](https://github.com/gotoUSA/selfhealing/blob/9836d194/Dockerfile)로 빌드해 로컬 레지스트리(`registry:3.1.2` 컨테이너, `localhost:5000`)에 올리고, 클러스터는 거기서 받음. kind 노드 안에서는 `localhost:5000`을 containerd 미러 설정으로 레지스트리 컨테이너에 연결
- 올린 것: PostgreSQL, Redis, 마이그레이션 Job, API(HPA로 2~6개), Celery 워커 2종, Beat 1개, metrics-server, Envoy Gateway(Gateway API, `https://localhost:8443`), NetworkPolicy(API에는 Envoy만)
- 설정: 쇼핑몰 운영 설정(`DJANGO_ENV: production`, `DEBUG` 꺼짐, HTTPS 리다이렉트). TLS는 Gateway에서 끝내고 자체 서명 인증서 사용
- 비밀값: `deploy.sh`가 생성해 클러스터 Secret에만 저장
- 배포: `deploy.sh`가 Helm으로 설치합니다. 앱은 [chart/](chart/), metrics-server는 공식 차트 3.14.0입니다. Envoy Gateway는 설치 파일(`addons/`)을 그대로 씁니다. 차트는 `manifests/`에서 이미지 태그·HPA 범위만 값으로 뺐고, 다른 점은 마이그레이션 Job(hook, DB 대기 init)과 Beat의 init(마이그레이션까지 대기) 두 곳입니다(비교 [tests/helm-template-diff.py](tests/helm-template-diff.py)). Secret은 차트에 넣지 않았습니다. `manifests/`는 Helm으로 옮기기 전 판이고 배포에 쓰지 않습니다.

## 재현

```bash
git clone https://github.com/gotoUSA/selfhealing.git build/src
git -C build/src checkout 9836d194
docker build -t shopping:9836d194 build/src
kind create cluster --config kind/cluster.yaml
bash deploy.sh   # Helm 4 필요(v4.3.1에서 확인). 다시 돌리면 helm upgrade
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
| kubectl로 올린 리소스를 Helm으로 넘겨받기 | `--take-ownership`만: server-side apply 필드 충돌로 실패 → `--force-conflicts`: `generation` 변화 없음, Pod 재시작 0 (1회) |
| `helm upgrade`(이미지 교체) → `helm rollback` | Deployment 4개 교체 후 되돌림, 새 revision으로 기록. 마이그레이션 hook은 rollback 때 돌지 않음 (1회) |
| 빈 클러스터에서 Helm으로 `deploy.sh` | 처음: Beat가 마이그레이션 전에 떠서 재시작 1번. Beat가 마이그레이션을 기다리게 하자 `--wait`와 서로 기다려 10분 시간 초과. `--wait=hookOnly`로 바꿔 4분 17초, 재시작 0. 다시 돌리면 upgrade 17초, Pod 교체 없음 (각 1회) |
| 다른 Pod에서 API로 직접 `X-Forwarded-Proto: https` 요청 | Docker Desktop: NetworkPolicy 적용 전후 모두 200(집행 안 됨, 1회). kind: 적용 전 200 → 적용 뒤 시간 초과, Gateway 경유 200, kubelet 검사 모두 200·재시작 0 (3회, [tests/networkpolicy-forge.sh](tests/networkpolicy-forge.sh)) |

## 알려진 문제

- 장고가 `X-Forwarded-Proto` 헤더를 믿습니다. 그래서 Gateway의 Envoy만 API Pod에 들어오게 하는 NetworkPolicy(`manifests/80-networkpolicy.yaml`)를 둡니다. 정책을 집행하는 네트워크(kind의 kindnet 등)에서만 효과가 있고, Docker Desktop 기본 네트워크에서는 효과가 없었습니다.
- HTTP를 8080에 열어서, `http://localhost:8080/` 리다이렉트가 `https://localhost:8080/`(HTTP 포트)으로 갑니다. HTTPS는 `https://localhost:8443/`으로 직접 엽니다.
- 인증서는 자체 서명이라 브라우저가 경고합니다.
- `tests/networkpolicy-forge.sh`, `tests/redis-persistence-run.sh`는 Helm 전에 만든 시험이라 `manifests/`를 `kubectl apply`합니다. Helm이 관리하는 지금 클러스터에서 돌리면 필드 소유가 kubectl로 가서 다음 `helm upgrade`가 충돌할 수 있습니다(돌려 보지 않음).
- Redis는 1개뿐입니다. 볼륨과 appendonly(`everysec`)로 교체·갑작스러운 종료 뒤에도 대기열이 남지만, Redis가 내려가 있는 동안은 작업을 보낼 수 없습니다.

HPA 시험은 부하 Pod와 API가 같은 PC의 CPU를 나눠 써서(부하 Pod 약 2코어), 늘고 주는 동작만 확인했고 처리량은 재지 않았습니다.

## 해 보지 않은 것

클라우드 배포, 실제 트래픽 운영, 외부 레지스트리(Docker Hub, 클라우드), 공인 인증서, 주문·결제 요청을 끝까지 처리하는 시험, 처리량 측정.
