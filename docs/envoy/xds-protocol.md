# xDS 프로토콜 가이드

> **작성일**: 2026-05-09
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

xDS (x Discovery Service)는 컨트롤 플레인 (istiod)이 데이터 플레인 (Envoy)에게 설정을 동적으로 전달하는 gRPC 기반 프로토콜임.

Istio에서 VirtualService/DestinationRule을 `kubectl apply`하면 istiod가 xDS를 통해 해당 설정을 클러스터 내 모든 Envoy 사이드카에 푸시함.

### xDS가 중요한 이유

Envoy 설정이 "왜 반영이 안 되지?"라는 문제의 근본 원인 대부분이 xDS 동기화 문제임. xDS 흐름을 이해하면 Istio 트러블슈팅 속도가 크게 향상됨.

---

## 2. xDS API 상세

### 4대 Discovery Service

| API | 풀네임 | 제어 대상 | Envoy 개념 |
|-----|--------|----------|-----------|
| **LDS** | Listener Discovery Service | 포트 수신 설정 | Listener |
| **RDS** | Route Discovery Service | HTTP 라우팅 규칙 | Route |
| **CDS** | Cluster Discovery Service | 업스트림 서비스 그룹 | Cluster |
| **EDS** | Endpoint Discovery Service | 실제 Pod IP:Port | Endpoint |

### 처리 순서 (의존 관계)

```
istiod
  │
  ├─ CDS 푸시 → Envoy가 Cluster 생성
  │               │
  ├─ EDS 푸시 → Cluster에 Endpoint 등록
  │
  ├─ LDS 푸시 → Envoy가 Listener 생성
  │               │
  └─ RDS 푸시 → Listener에 Route 규칙 연결
```

LDS/RDS와 CDS/EDS는 독립적으로 동작하지만, Listener가 Route를 참조하고 Route가 Cluster를 참조하므로 모두 동기화되어야 트래픽이 정상 처리됨.

---

### LDS (Listener Discovery Service)

```bash
# 현재 Envoy가 수신 중인 Listener 목록
istioctl proxy-config listener <POD_NAME> -n default

# 예시 출력
# ADDRESS          PORT  MATCH   DESTINATION
# 0.0.0.0         15006 ALL     Inline Route: /
# 0.0.0.0         15001 ALL     PassthroughCluster
# 10.100.200.50   8080  ALL     Cluster: outbound|8080||my-app.default.svc.cluster.local

# JSON으로 전체 Listener 구조 확인
istioctl proxy-config listener <POD_NAME> -n default -o json
```

**Istio가 생성하는 Listener 종류:**

| 리스너 | 주소:포트 | 역할 |
|--------|----------|------|
| 가상 인바운드 | `0.0.0.0:15006` | 모든 인바운드 트래픽 수신 |
| 가상 아웃바운드 | `0.0.0.0:15001` | 모든 아웃바운드 트래픽 수신 |
| 서비스별 | `<ClusterIP>:<Port>` | 특정 서비스행 트래픽 |

---

### RDS (Route Discovery Service)

```bash
# Route 구성 확인 (HTTP 라우팅 규칙)
istioctl proxy-config route <POD_NAME> -n default

# 예시 출력
# NAME                                DOMAINS                MATCH     VIRTUAL SERVICE
# 8080                                my-app, my-app.default my-app-vs

# 특정 Route 상세 확인 (VirtualService 적용 여부 포함)
istioctl proxy-config route <POD_NAME> -n default --name 8080 -o json
```

VirtualService를 적용했는데 라우팅이 안 된다면 RDS에 규칙이 반영됐는지 먼저 확인.

---

### CDS (Cluster Discovery Service)

```bash
# Cluster 목록 확인
istioctl proxy-config cluster <POD_NAME> -n default

# 예시 출력
# SERVICE FQDN                          PORT  SUBSET  DIRECTION  TYPE
# my-app.default.svc.cluster.local      8080  -       outbound   EDS
# my-app.default.svc.cluster.local      8080  v1      outbound   EDS
# my-app.default.svc.cluster.local      8080  v2      outbound   EDS

# DestinationRule subset이 Cluster로 변환됐는지 확인
istioctl proxy-config cluster <POD_NAME> -n default \
  --fqdn my-app.default.svc.cluster.local -o json
```

---

### EDS (Endpoint Discovery Service)

```bash
# Endpoint 목록 확인 (실제 Pod IP 등록 여부)
istioctl proxy-config endpoint <POD_NAME> -n default

# 예시 출력
# ENDPOINT             STATUS  OUTLIER CHECK  CLUSTER
# 192.168.1.10:8080    HEALTHY OK             outbound|8080|v1|my-app.default.svc.cluster.local
# 192.168.1.11:8080    HEALTHY OK             outbound|8080|v2|my-app.default.svc.cluster.local

# 특정 Cluster의 Endpoint 상태 확인
istioctl proxy-config endpoint <POD_NAME> -n default \
  --cluster "outbound|8080|v1|my-app.default.svc.cluster.local"
```

---

### xDS 동기화 상태 확인

```bash
# 전체 Envoy의 동기화 상태 한 번에 확인
istioctl proxy-status

# 예시 출력
# NAME                           CDS  LDS  EDS  RDS  ECDS  ISTIOD
# my-app-v1-xxx.default          SYNCED SYNCED SYNCED SYNCED SYNCED istiod-xxx
# my-app-v2-xxx.default          SYNCED SYNCED SYNCED SYNCED SYNCED istiod-xxx

# NOT SENT: istiod가 아직 해당 설정을 보내지 않음
# STALE:    Envoy가 설정을 받았지만 아직 적용 중
# ERROR:    설정 수신 실패
```

---

### Delta xDS (증분 업데이트)

Istio 1.12+ 기본값으로 전체 설정이 아닌 변경된 부분만 전송하는 델타 xDS (Delta xDS) 사용.

```bash
# Delta xDS 사용 여부 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("DiscoveryRequest"))'
```

---

## 3. 트러블슈팅

### 증상: VirtualService 적용 후 라우팅이 바뀌지 않음

#### 원인
RDS 동기화 지연 또는 VirtualService 스펙 오류로 istiod가 규칙을 생성하지 못함

#### 해결 방법

```bash
# 1. istiod가 VirtualService를 정상 인식했는지 확인
istioctl analyze -n default

# 2. RDS에 새 라우팅 규칙이 반영됐는지 확인
istioctl proxy-config route <POD_NAME> -n default --name 8080 -o json | \
  jq '.[].virtualHosts[].routes'

# 3. 동기화 상태 확인
istioctl proxy-status | grep <POD_NAME>

# 4. istiod가 xDS 푸시를 완료했는지 확인
kubectl logs -n istio-system deployment/istiod | grep "Push" | tail -20
```

---

### 증상: `STALE` 상태가 지속됨

#### 원인
Envoy와 istiod 간 gRPC 연결 문제 또는 대규모 설정 변경으로 처리 지연

#### 해결 방법

```bash
# 1. istiod와 연결 상태 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep xds-grpc

# 2. Envoy 재시작 (최후 수단, Pod 재시작)
kubectl rollout restart deployment/my-app -n default

# 3. istiod 상태 확인
kubectl get pods -n istio-system
kubectl logs -n istio-system deployment/istiod | tail -50
```

---

## 4. 모니터링 및 확인

```bash
# xDS 푸시 통계 확인 (istiod 기준)
kubectl exec -n istio-system deployment/istiod -- \
  curl -s http://localhost:15014/metrics | grep pilot_xds

# 핵심 지표
# pilot_xds_push_time_bucket: 푸시 소요 시간 분포
# pilot_xds_pushes: 푸시 횟수 (타입별)
# pilot_xds_write_timeout: 푸시 타임아웃 횟수

# Envoy 측 xDS 수신 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "cluster_manager"
```

### Prometheus 쿼리

```promql
# istiod xDS 푸시 에러율
rate(pilot_xds_write_timeout[5m])

# 평균 xDS 푸시 지연
histogram_quantile(0.99, rate(pilot_xds_push_time_bucket[5m]))
```

---

## 5. TIP

- `istioctl proxy-status`는 istiod 관점의 동기화 상태를 보여줌. 실제 Envoy 내부 상태는 `proxy-config`로 직접 확인해야 함
- xDS 설정 변경은 Envoy 재시작 없이 hot reload로 적용됨
- 클러스터 규모가 크면 xDS 푸시 지연이 발생할 수 있음. istiod의 `PILOT_PUSH_THROTTLE` 환경변수로 조절 가능
- Envoy가 수신한 raw xDS 응답 확인: `curl -s http://localhost:15000/config_dump > dump.json`
