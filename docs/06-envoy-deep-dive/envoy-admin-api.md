# Envoy Admin API 가이드

> **작성일**: 2026-05-09
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Envoy Admin API는 Envoy 내부 상태를 실시간으로 조회하고 일부 런타임 설정을 변경할 수 있는 HTTP 인터페이스임. Istio 사이드카에서는 `localhost:15000`에서 접근 가능.

### 포트 용도 정리

| 포트 | 용도 | 접근 |
|------|------|------|
| `15000` | Envoy Admin API | localhost 전용 |
| `15001` | 아웃바운드 트래픽 수신 (iptables) | iptables redirect |
| `15006` | 인바운드 트래픽 수신 (iptables) | iptables redirect |
| `15020` | 헬스체크, 머지된 Prometheus 지표 | Pod 내/외부 |
| `15021` | Istio 헬스체크 엔드포인트 | Pod 내/외부 |
| `15090` | Envoy Prometheus 지표 (raw) | Pod 내/외부 |

---

## 2. 주요 Admin API 엔드포인트

### 기본 접근 방법

```bash
# kubectl exec로 Admin API 접근
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/<ENDPOINT>

# 또는 port-forward 후 브라우저에서 접근
kubectl port-forward <POD_NAME> -n default 15000:15000
# 브라우저: http://localhost:15000
```

---

### `/config_dump` — 전체 xDS 설정 덤프

Envoy가 현재 갖고 있는 모든 설정(Listener, Route, Cluster, Endpoint)을 JSON으로 출력함. 가장 중요한 디버깅 엔드포인트.

```bash
# 전체 설정 덤프 (용량이 큼)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump > /tmp/envoy-dump.json

# Listener만 추출
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" | contains("ListenersConfigDump"))'

# Route만 추출
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" | contains("RoutesConfigDump"))'

# Cluster만 추출
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" | contains("ClustersConfigDump"))'

# 특정 서비스 관련 설정만 필터링
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.. | strings | select(contains("my-app"))'
```

---

### `/clusters` — Cluster 및 Endpoint 상태

각 Cluster의 Endpoint 상태와 연결 통계를 확인함.

```bash
# 전체 Cluster 목록 및 Endpoint 상태 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters

# 예시 출력 (주요 필드)
# outbound|8080|v1|my-app.default.svc.cluster.local::192.168.1.10:8080::health_flags::healthy
# outbound|8080|v1|my-app.default.svc.cluster.local::192.168.1.10:8080::cx_active::2
# outbound|8080|v1|my-app.default.svc.cluster.local::192.168.1.10:8080::rq_active::1

# JSON 형식으로 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s "http://localhost:15000/clusters?format=json" | \
  jq '.cluster_statuses[] | {name, added_via_api, host_statuses}'

# UNHEALTHY Endpoint만 필터링
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep -v "healthy$" | grep "health_flags"
```

**health_flags 해석:**

| 플래그 | 의미 |
|--------|------|
| `healthy` | 정상 |
| `/failed_active_hc` | Active Health Check 실패 |
| `/pending_active_hc` | Health Check 대기 중 |
| `/failed_outlier_check` | Outlier Detection으로 제거됨 (Circuit Breaker) |
| `/failed_eds_health` | EDS에서 UNHEALTHY로 마킹 |

---

### `/stats` — 내부 통계

Envoy의 모든 처리 통계를 확인함. Prometheus가 `/stats/prometheus`에서 이 데이터를 수집함.

```bash
# 전체 통계 출력 (매우 많음)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats

# 특정 Cluster 통계만 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "my-app"

# 아웃바운드 연결 관련 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_cx"

# 요청 재시도 횟수
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_rq_retry"

# Circuit Breaker (Outlier Detection) 이탈 횟수
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "outlier_detection"
```

**주요 통계 항목:**

| 통계 | 의미 |
|------|------|
| `downstream_cx_active` | 현재 활성 인바운드 연결 수 |
| `upstream_cx_active` | 현재 활성 아웃바운드 연결 수 |
| `upstream_cx_overflow` | Connection Pool 초과 횟수 (UO 플래그 원인) |
| `upstream_rq_active` | 처리 중인 아웃바운드 요청 수 |
| `upstream_rq_retry` | 재시도 횟수 |
| `upstream_rq_timeout` | 타임아웃 횟수 |
| `ejections_active` | 현재 Outlier Detection으로 제거된 Endpoint 수 |

---

### `/logging` — 로그 레벨 조정

특정 컴포넌트의 로그 레벨을 런타임에 변경할 수 있음.

```bash
# 현재 로그 레벨 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/logging

# 전체 로그 레벨 debug로 변경
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/logging?level=debug"

# 특정 컴포넌트만 debug
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/logging?http=debug"

# 원복 (운영 환경에서 반드시 원복)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/logging?level=warning"
```

**주요 로그 컴포넌트:**

| 컴포넌트 | 디버깅 대상 |
|----------|-----------|
| `http` | HTTP 요청/응답 처리 |
| `router` | 라우팅 결정 |
| `upstream` | 업스트림 연결 |
| `connection` | TCP 연결 |
| `lua` | Lua 필터 실행 |
| `jwt` | JWT 검증 |
| `rbac` | RBAC 접근 제어 |

---

### `/runtime` — 런타임 설정 확인

```bash
# 현재 런타임 설정 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/runtime | jq .
```

---

### `/ready` & `/server_info` — 상태 확인

```bash
# Envoy 준비 상태 확인 (헬스체크)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/ready

# Envoy 버전 및 빌드 정보
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/server_info | jq '{version, state, uptime_current_epoch}'
```

---

## 3. 트러블슈팅

### 증상: 특정 서비스 요청이 계속 다른 Cluster로 라우팅됨

#### 원인
Route 설정이 의도한 Cluster를 가리키지 않거나 Endpoint가 잘못된 Cluster에 있음

#### 해결 방법

```bash
# 1. Route에서 어떤 Cluster로 연결되는지 확인
istioctl proxy-config route <POD_NAME> -n default --name 8080 -o json | \
  jq '.[].virtualHosts[].routes[].route.cluster'

# 2. /config_dump에서 route → cluster 연결 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" | contains("RoutesConfigDump")) |
      .dynamic_route_configs[].route_config.virtual_hosts[].routes[].route'

# 3. /clusters에서 해당 Cluster의 Endpoint 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "my-app"
```

---

### 증상: Circuit Breaker가 예상보다 자주 동작함

#### 원인
Connection Pool 설정이 너무 낮거나 Outlier Detection 기준이 과민하게 설정됨

#### 해결 방법

```bash
# Outlier Detection 이탈 통계 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep -E "ejection|outlier"

# 현재 이탈된 Endpoint 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "failed_outlier_check"

# DestinationRule outlierDetection 설정 확인
kubectl get destinationrule my-app-dr -n default -o yaml | grep -A 10 outlierDetection
```

---

## 4. 모니터링 및 확인

```bash
# 전체 Admin API 엔드포인트 목록 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/ | grep -oP '(?<=href=")[^"]*'

# 핵심 상태 원라이너 (운영 진단 시)
kubectl exec <POD_NAME> -n default -c istio-proxy -- bash -c "
  echo '=== Server Info ===' && curl -s http://localhost:15000/server_info | jq '{version, state}';
  echo '=== UNHEALTHY Endpoints ===' && curl -s http://localhost:15000/clusters | grep 'failed';
  echo '=== Key Stats ===' && curl -s http://localhost:15000/stats | grep -E 'cx_overflow|rq_timeout|ejections_active';
"
```

---

## 5. TIP

- `15000` 포트는 localhost 전용. Pod 외부에서는 `kubectl exec` 또는 `kubectl port-forward` 사용
- `/config_dump` 출력 결과를 저장해두면 설정 변경 전후 비교 (`diff`)에 유용
- 로그 레벨을 `debug`로 변경하면 트래픽이 많은 환경에서 로그가 폭증함. 조사 후 반드시 `warning`으로 원복
- `istioctl proxy-config` 명령은 내부적으로 이 Admin API를 활용함
