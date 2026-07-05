# Envoy 아키텍처 심층 가이드

> **작성일**: 2026-05-09
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Envoy는 Istio 데이터 플레인 (Data Plane)의 핵심 컴포넌트로, 각 Pod에 사이드카 (Sidecar) 형태로 주입되어 모든 인바운드/아웃바운드 트래픽을 가로채 처리함.

### Envoy가 필요한 이유

| 기능 | Envoy 없을 때 | Envoy 있을 때 |
|------|--------------|--------------|
| 트래픽 제어 | 앱 코드 직접 구현 | 사이드카가 투명하게 처리 |
| mTLS | 앱마다 인증서 관리 | 자동 TLS 핸드셰이크 |
| 관측성 (Observability) | 별도 계측 코드 | 자동 메트릭/트레이스 수집 |
| 재시도/타임아웃 | 앱 로직에 포함 | Envoy 설정으로 분리 |

---

## 2. 핵심 아키텍처

### 트래픽 처리 흐름

```
[클라이언트 Pod]
     │
     ▼
┌─────────────────────────────────────────┐
│  Envoy Sidecar (istio-proxy)            │
│                                         │
│  Listener (포트 수신)                   │
│     │                                   │
│     ▼                                   │
│  Filter Chain (필터 처리)               │
│     │  ├── Network Filter               │
│     │  └── HTTP Filter (L7인 경우)      │
│     │                                   │
│     ▼                                   │
│  Route (라우팅 결정)                    │
│     │                                   │
│     ▼                                   │
│  Cluster (업스트림 그룹 선택)           │
│     │                                   │
│     ▼                                   │
│  Endpoint (실제 서버 IP:Port)           │
└─────────────────────────────────────────┘
     │
     ▼
[서버 Pod]
```

### 핵심 4대 개념

| 개념 | 역할 | Istio 매핑 |
|------|------|-----------|
| **Listener** | 특정 IP:Port에서 연결 수신 | VirtualService의 hosts/port |
| **Filter Chain** | 트래픽에 적용할 처리 로직 시퀀스 | EnvoyFilter |
| **Cluster** | 업스트림 서비스 논리 그룹 | DestinationRule subset |
| **Endpoint** | 실제 업스트림 서버 주소 (IP:Port) | Pod IP |

---

### Listener 상세

Envoy는 두 종류의 리스너를 가짐:

```
# 인바운드: 외부 → 이 Pod로 들어오는 트래픽
0.0.0.0:15006   (iptables가 모든 인바운드를 여기로 리다이렉트)

# 아웃바운드: 이 Pod → 외부로 나가는 트래픽
0.0.0.0:15001   (iptables가 모든 아웃바운드를 여기로 리다이렉트)
```

```bash
# 현재 Pod의 리스너 목록 확인
istioctl proxy-config listener <POD_NAME> -n default

# 특정 포트 리스너 상세 확인
istioctl proxy-config listener <POD_NAME> -n default --port 8080 -o json
```

---

### Filter Chain 상세

리스너가 연결을 받으면 Filter Chain을 순서대로 실행함.

**L4 (TCP) 레벨 필터:**

| 필터 | 역할 |
|------|------|
| `envoy.filters.network.tcp_proxy` | TCP 프록시 (L4 라우팅) |
| `envoy.filters.network.http_connection_manager` | HTTP 처리 진입점 (L7) |
| `envoy.filters.network.rbac` | L4 접근 제어 |

**L7 (HTTP) 레벨 필터 (HCM 내부):**

| 필터 | 역할 |
|------|------|
| `envoy.filters.http.router` | 최종 라우팅 (필수, 마지막에 위치) |
| `envoy.filters.http.jwt_authn` | JWT 검증 |
| `envoy.filters.http.rbac` | L7 접근 제어 |
| `envoy.filters.http.fault` | Fault Injection |
| `envoy.filters.http.lua` | Lua 스크립트 |

```bash
# Filter Chain 확인
istioctl proxy-config listener <POD_NAME> -n default -o json | \
  jq '.[].filterChains[].filters[].name'
```

---

### Cluster 상세

Cluster는 부하 분산 (Load Balancing) 대상 그룹을 정의함.

```bash
# Cluster 목록 확인
istioctl proxy-config cluster <POD_NAME> -n default

# 예시 출력
# SERVICE FQDN                         PORT  SUBSET  DIRECTION  TYPE
# my-app.default.svc.cluster.local     8080  v1      outbound   EDS
# my-app.default.svc.cluster.local     8080  v2      outbound   EDS

# 특정 Cluster 상세 확인
istioctl proxy-config cluster <POD_NAME> -n default \
  --fqdn my-app.default.svc.cluster.local -o json
```

**Cluster 타입:**

| 타입 | 설명 | 사용 시점 |
|------|------|---------|
| `EDS` | xDS로 동적 Endpoint 수신 | 일반적인 쿠버네티스 서비스 |
| `STATIC` | 고정 IP 목록 | ServiceEntry STATIC |
| `STRICT_DNS` | DNS 조회로 Endpoint 결정 | 외부 도메인 |
| `ORIGINAL_DST` | 원래 목적지로 전달 | Passthrough |

---

### Endpoint 상세

```bash
# Endpoint 목록 확인 (Pod IP가 실제로 등록되었는지 확인)
istioctl proxy-config endpoint <POD_NAME> -n default

# 특정 서비스 Endpoint 확인
istioctl proxy-config endpoint <POD_NAME> -n default \
  --cluster "outbound|8080|v1|my-app.default.svc.cluster.local"
```

---

## 3. 트러블슈팅

### 증상: 특정 서비스로 요청이 가지 않음 (503 에러)

#### 원인
Envoy의 Cluster에 Endpoint가 없거나 UNHEALTHY 상태

#### 해결 방법

```bash
# 1. Endpoint 상태 확인
istioctl proxy-config endpoint <POD_NAME> -n default | grep my-app

# 2. Endpoint가 없다면 Pod 레이블 확인 (DestinationRule subset과 일치해야 함)
kubectl get pods -n default --show-labels | grep my-app

# 3. Pilot (istiod)이 Endpoint를 인식하는지 확인
istioctl proxy-status -n default

# 4. Pilot 로그에서 Endpoint 푸시 확인
kubectl logs -n istio-system deployment/istiod | grep "my-app"
```

---

### 증상: Listener가 특정 포트를 수신하지 않음

#### 원인
해당 포트에 대한 Service 리소스가 없거나 VirtualService가 잘못 구성됨

#### 해결 방법

```bash
# 리스너 전체 목록 확인
istioctl proxy-config listener <POD_NAME> -n default

# 특정 포트 리스너 존재 여부 확인
istioctl proxy-config listener <POD_NAME> -n default --port <PORT>

# Istio 구성 분석
istioctl analyze -n default
```

---

## 4. 모니터링 및 확인

```bash
# Envoy 전체 구성 덤프 (xDS 수신 상태 포함)
istioctl proxy-config all <POD_NAME> -n default -o json

# 컨트롤 플레인 동기화 상태 확인
istioctl proxy-status

# Envoy 내부 통계 확인 (Admin API)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep downstream_cx

# Envoy → istiod 연결 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep xds-grpc
```

### 핵심 모니터링 지표

| 지표 | 의미 | 확인 방법 |
|------|------|---------|
| `downstream_cx_active` | 현재 활성 인바운드 연결 수 | Admin API /stats |
| `upstream_cx_active` | 현재 활성 아웃바운드 연결 수 | Admin API /stats |
| `upstream_rq_retry` | 재시도 횟수 | Prometheus |
| `upstream_rq_timeout` | 타임아웃 횟수 | Prometheus |

---

## 5. TIP

- Envoy는 `iptables` 규칙을 통해 트래픽을 가로채므로 앱 코드 변경 없이 동작함
- `istio-init` 컨테이너가 Pod 시작 시 `iptables` 규칙을 설정함
- `istioctl proxy-config` 명령은 실제 Envoy가 갖고 있는 설정을 실시간으로 조회함 (istiod 설정과 다를 수 있음)
- Envoy 버전은 Istio 버전에 종속: `kubectl exec <POD> -c istio-proxy -- envoy --version`
