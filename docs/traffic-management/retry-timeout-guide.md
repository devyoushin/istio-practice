# Retry & Timeout 실무 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Retry와 Timeout은 서비스 메시의 복원력 (Resiliency) 핵심 설정임. 잘못 설정하면 재시도가 장애를 증폭시키거나 (Retry Storm), 타임아웃이 너무 짧아 정상 요청을 실패로 처리하는 문제가 발생함.

### Retry vs Timeout 관계

```
Client → Envoy → 업스트림

Timeout = 단일 시도의 최대 허용 시간
Retry   = 실패 시 재시도 횟수

전체 최대 시간 = perTryTimeout × attempts
```

**중요**: `timeout`이 `perTryTimeout × attempts`보다 짧으면 재시도 전에 전체 타임아웃이 먼저 발동함.

---

## 2. 설정 상세

### VirtualService Retry 설정

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app-vs
  namespace: default
spec:
  hosts:
    - my-app
  http:
    - name: main-route
      route:
        - destination:
            host: my-app
            subset: v1
      timeout: 15s              # 전체 요청 타임아웃 (재시도 포함)
      retries:
        attempts: 3             # 최대 재시도 횟수 (초기 시도 제외)
        perTryTimeout: 4s       # 개별 시도 타임아웃
        retryOn: gateway-error,connect-failure,retriable-4xx
```

### retryOn 조건 상세

| 조건 | 재시도 트리거 | 비고 |
|------|------------|------|
| `gateway-error` | 502, 503, 504 | 업스트림 게이트웨이 에러 |
| `connect-failure` | TCP 연결 실패 | 응답 플래그 UF |
| `retriable-4xx` | 409 Conflict | 멱등성 보장된 경우만 사용 |
| `reset` | 연결 리셋 (RST) | 응답 플래그 UC/UR |
| `5xx` | 모든 5xx | 주의: POST에도 재시도됨 |
| `retriable-status-codes` | 커스텀 코드 | 아래 예시 참고 |

```yaml
# 커스텀 재시도 코드 지정
retries:
  attempts: 3
  perTryTimeout: 4s
  retryOn: retriable-status-codes
  retryRemoteStatuses: "503,429"   # 503과 429만 재시도
```

---

### 실무 권장값

| 서비스 유형 | attempts | perTryTimeout | timeout | retryOn |
|-----------|---------|--------------|---------|---------|
| 일반 REST API | 3 | 3s | 10s | `gateway-error,connect-failure` |
| 데이터베이스 조회 | 2 | 5s | 12s | `connect-failure` |
| 외부 API 호출 | 2 | 10s | 25s | `gateway-error,connect-failure` |
| gRPC 스트리밍 | 1 | - | 300s | `reset` |
| 멱등성 없는 POST | 1 | 10s | 10s | `connect-failure` (5xx 제외) |

---

### Timeout 레이어별 설정

Istio에서 타임아웃은 여러 레이어에 중복 설정 가능하며 **가장 먼저 만료되는 값이 적용**됨.

```
[클라이언트 앱 자체 타임아웃]    ← 앱 코드 수준
         │
         ▼
[VirtualService timeout]         ← Envoy 수준 (권장 설정 위치)
         │
         ▼
[DestinationRule connectTimeout] ← TCP 연결 수립 타임아웃만
         │
         ▼
[업스트림 앱 처리 시간]
```

```yaml
# DestinationRule: TCP 연결 타임아웃만 설정
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    connectionPool:
      tcp:
        connectTimeout: 3s      # TCP handshake 타임아웃
```

---

### 헤더로 Per-Request Timeout 오버라이드

개별 요청에서 타임아웃을 동적으로 오버라이드 가능.

```bash
# x-envoy-upstream-rq-timeout-ms: 이 요청에만 타임아웃 적용 (ms)
curl -H "x-envoy-upstream-rq-timeout-ms: 500" http://my-app:8080/api

# x-envoy-max-retries: 이 요청에만 재시도 횟수 오버라이드
curl -H "x-envoy-max-retries: 0" http://my-app:8080/api  # 재시도 비활성화
```

---

## 3. 트러블슈팅

### 증상: 재시도로 인해 장애가 오히려 증폭됨 (Retry Storm)

#### 원인
업스트림이 이미 과부하 상태인데 재시도가 추가 트래픽을 생성해 회복을 방해

#### 해결 방법

```yaml
# 재시도 횟수를 줄이고 retryOn 조건 제한
retries:
  attempts: 2                    # 3 → 2로 감소
  perTryTimeout: 3s
  retryOn: connect-failure       # gateway-error 제거 (5xx 재시도 중단)
```

```bash
# 재시도 횟수 통계 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_rq_retry"

# Circuit Breaker와 함께 사용 (Retry Storm 방지)
# outlierDetection으로 불량 Endpoint 자동 제거 후 재시도
```

---

### 증상: timeout 설정했는데 더 빨리 타임아웃됨

#### 원인
`perTryTimeout × attempts < timeout` 조건이 맞지 않거나 클라이언트 앱 자체 타임아웃이 더 짧음

#### 해결 방법

```bash
# Access Log에서 실제 duration 확인
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  jq 'select(.response_flags == "UT") | {duration_ms, upstream_service_time_ms}'

# UT(Upstream Timeout) 플래그: VirtualService timeout 발동
# DI(Delay Injected): Fault Injection delay 발동

# 현재 VirtualService 설정 확인
kubectl get virtualservice my-app-vs -n default -o yaml | grep -A 5 "timeout\|retries"
```

---

## 4. 모니터링 및 확인

```bash
# 타임아웃 발생 횟수
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_rq_timeout"

# 재시도 횟수 및 성공률
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "upstream_rq_retry($| )"

# Access Log에서 UT 플래그 (타임아웃) 필터링
kubectl logs <POD_NAME> -n default -c istio-proxy | grep '"response_flags":"UT"'
```

### Prometheus 쿼리

```promql
# 서비스별 타임아웃 비율
sum(rate(istio_requests_total{
  response_flags="UT",
  destination_service_name="my-app"
}[5m])) /
sum(rate(istio_requests_total{
  destination_service_name="my-app"
}[5m]))

# 재시도 발생률
rate(envoy_cluster_upstream_rq_retry[5m])
```

---

## 5. TIP

- `retryOn: 5xx`는 POST/PUT 같은 비멱등성 요청에도 재시도하므로 중복 처리 위험. `connect-failure,gateway-error`만 사용 권장
- 재시도 간격은 기본적으로 지수 백오프 (Exponential Backoff)로 동작하지 않음. Envoy는 즉시 재시도함. 과부하 상황에서는 Circuit Breaker와 함께 사용
- gRPC의 경우 `retryOn`에 `reset,cancelled,resource-exhausted` 추가 고려
- `x-envoy-retry-on` 헤더로 요청별 재시도 조건을 오버라이드 가능 — 테스트 환경에서 유용
