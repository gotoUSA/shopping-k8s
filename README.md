# shopping-k8s

Django 쇼핑몰 API([gotoUSA/selfhealing](https://github.com/gotoUSA/selfhealing))를 로컬 Kubernetes 클러스터에 배포하고, 장애와 버전 교체를 시험한 기록입니다. Kubernetes는 2026년 11월에 처음 사용했습니다. **운영 경험이 아니라 로컬 클러스터 실습입니다.**

매니페스트 작성과 분석에는 Claude Code를 사용했습니다. 실행 주체는 [RECORD.md](RECORD.md)에 시험별로 나눠 적었고, 기록의 "사용자"는 이 저장소 작성자입니다.

## 실행 화면

| 내용 | 이미지 | 원문 |
|---|---|---|
| 클러스터와 Pod 상태 | [PNG](evidence/01-cluster-state.png) | [txt](evidence/01-cluster-state.txt) |
| 요청을 보내며 버전 교체 | [PNG](evidence/02-rolling-update.png) | [txt](evidence/02-rolling-update.txt) |
| API·워커 로그 | [PNG](evidence/03-logs.png) | [txt](evidence/03-logs.txt) |

PNG는 실제 명령 출력을 `evidence/render.py`로 그린 이미지입니다. `evidence/capture.sh`로 다시 만들 수 있습니다.

## 구성

- 클러스터: Docker Desktop Kubernetes, 노드 1개
- 이미지: 쇼핑몰 저장소의 [Dockerfile](https://github.com/gotoUSA/selfhealing/blob/9836d194/Dockerfile)로 빌드한 로컬 이미지, 레지스트리 미사용
- 올린 것: PostgreSQL, Redis, 마이그레이션 Job, API(HPA로 2~6개), Celery 워커 2종, Beat 1개, metrics-server
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

HPA 시험은 부하 Pod와 API가 같은 PC의 CPU를 나눠 써서(부하 Pod 약 2코어), 늘고 주는 동작만 확인했고 처리량은 재지 않았습니다.

## 해 보지 않은 것

클라우드 배포, 실제 트래픽 운영, 레지스트리 업로드, Ingress, 주문·결제 요청을 끝까지 처리하는 시험, 처리량 측정.
