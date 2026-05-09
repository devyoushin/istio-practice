# Envoy Access Log 가이드

> **작성일**: 2026-05-09
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Envoy Access Log는 Envoy가 처리한 모든 요청/응답에 대한 상세 기록임. Istio는 기본적으로 사이드카와 게이트웨이에서 Access Log를 수집하며, 이를 통해 4xx/5xx 에러의 정확한 원인, 지연 발생 구간, 트래픽 경로를 추적할 수 있음.

### 기본 로그 필드 해석

```
[2026-05-09T12:00:00.000Z] "GET /api/v1/users HTTP/1.1" 200 - via_upstream - "-" 0 1234 45 44 "-" "curl/7.68.0" "req-id-xyz" "my-app" "192.168.1.10:8080"
```

| 필드 | 값 | 의미 |
|------|----|------|
| 타임스탬프 | `2026-05-09T12:00:00.000Z` | 요청 시작 시간 |
| 메서드/경로 | `GET /api/v1/users HTTP/1.1` | HTTP 요청 정보 |
| 응답 코드 | `200` | HTTP 상태 코드 |
| 응답 플래그 | `-` | Envoy 처리 결과 플래그 |
| 업스트림 정보 | `via_upstream` | 트래픽 처리 경로 |
| 바이트 | `0 / 1234` | 요청/응답 바이트 |
| 지연 | `45 / 44` | 전체 지연 / 업스트림 지연 (ms) |

---

## 2. Access Log 상세

### 응답 플래그 (Response Flags)

Envoy 에러 디버깅에서 가장 중요한 필드. 오류 발생 시 `-` 대신 아래 플래그가 표시됨.

| 플래그 | 의미 | 주요 원인 |
|--------|------|---------|
| `UH` | No healthy upstream | Endpoint 없음 / 모두 UNHEALTHY |
| `UF` | Upstream connection failure | 업스트림 연결 실패 (Connection Refused 등) |
| `UO` | Upstream overflow | Connection Pool 한도 초과 (Circuit Breaker) |
| `UR` | Upstream remote reset | 업스트림이 연결 강제 종료 |
| `UC` | Upstream connection termination | 업스트림 연결 이상 종료 |
| `DI` | Delay injected | Fault Injection - delay 적용됨 |
| `FI` | Fault injected | Fault Injection - abort 적용됨 |
| `RL` | Rate limited | Rate Limit 적용됨 |
| `UMSDR` | Upstream max stream duration reached | 스트림 최대 시간 초과 |
| `NR` | No route | 라우팅 규칙 없음 |
| `DC` | Downstream connection termination | 클라이언트가 연결 종료 |

**운영에서 자주 보는 플래그 조합:**

```
200 UH  → Cluster는 존재하지만 Endpoint가 없음 (Pod 다운, 레이블 불일치)
503 UF  → 업스트림 Pod에 연결 자체가 안 됨 (포트 오류, mTLS 불일치)
503 UO  → Circuit Breaker 동작 중 (Connection Pool 초과)
503 NR  → VirtualService에 해당 호스트/경로 라우팅 규칙 없음
```

---

### Access Log 포맷 커스터마이징

기본 포맷을 JSON으로 변경하면 로그 파싱이 용이해짐.

**MeshConfig를 통한 전역 설정:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |-
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON
    accessLogFormat: |
      {
        "timestamp": "%START_TIME%",
        "method": "%REQ(:METHOD)%",
        "path": "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%",
        "protocol": "%PROTOCOL%",
        "response_code": "%RESPONSE_CODE%",
        "response_flags": "%RESPONSE_FLAGS%",
        "bytes_received": "%BYTES_RECEIVED%",
        "bytes_sent": "%BYTES_SENT%",
        "duration_ms": "%DURATION%",
        "upstream_service_time_ms": "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%",
        "x_forwarded_for": "%REQ(X-FORWARDED-FOR)%",
        "user_agent": "%REQ(USER-AGENT)%",
        "request_id": "%REQ(X-REQUEST-ID)%",
        "upstream_host": "%UPSTREAM_HOST%",
        "upstream_cluster": "%UPSTREAM_CLUSTER%",
        "upstream_local_address": "%UPSTREAM_LOCAL_ADDRESS%",
        "downstream_remote_address": "%DOWNSTREAM_REMOTE_ADDRESS%",
        "trace_id": "%REQ(X-B3-TRACEID)%"
      }
```

```bash
# ConfigMap 적용 후 istiod 재시작 없이 반영됨 (Watch 기반)
kubectl apply -f istio-mesh-config.yaml -n istio-system

# 반영 확인 (사이드카는 재시작 필요)
kubectl rollout restart deployment/my-app -n default
```

---

### Telemetry API로 네임스페이스별 설정 (Istio 1.12+)

전역 설정 대신 네임스페이스 단위로 Access Log를 커스터마이징할 수 있음.

```yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: access-log-custom
  namespace: default        # 이 네임스페이스에만 적용
spec:
  accessLogging:
    - providers:
        - name: envoy       # 기본 stdout 로깅
      disabled: false
```

**특정 Pod에만 Access Log 비활성화:**

```yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: disable-access-log
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  accessLogging:
    - disabled: true
```

---

### Access Log에서 유용한 포맷 변수

| 변수 | 의미 |
|------|------|
| `%START_TIME%` | 요청 시작 시간 |
| `%RESPONSE_CODE%` | HTTP 응답 코드 |
| `%RESPONSE_FLAGS%` | Envoy 응답 플래그 |
| `%DURATION%` | 전체 요청 처리 시간 (ms) |
| `%UPSTREAM_HOST%` | 실제 업스트림 IP:Port |
| `%UPSTREAM_CLUSTER%` | 업스트림 Cluster 이름 |
| `%REQ(X-REQUEST-ID)%` | 요청 추적 ID |
| `%REQ(X-B3-TRACEID)%` | Jaeger/Zipkin Trace ID |
| `%BYTES_RECEIVED%` | 수신 바이트 |
| `%BYTES_SENT%` | 송신 바이트 |
| `%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%` | 업스트림 처리 시간 (ms) |

---

## 3. 트러블슈팅

### 증상: Access Log에 아무것도 출력되지 않음

#### 원인
`accessLogFile`이 설정되지 않았거나 빈 문자열로 설정됨 (Istio 기본값은 비활성화)

#### 해결 방법

```bash
# 현재 MeshConfig 확인
kubectl get configmap istio -n istio-system -o yaml | grep accessLog

# accessLogFile: "" 이면 비활성화 상태
# 활성화: accessLogFile: /dev/stdout 으로 변경

kubectl edit configmap istio -n istio-system
# accessLogFile: /dev/stdout 추가

# 사이드카에 반영 (재시작 필요)
kubectl rollout restart deployment/my-app -n default

# 로그 확인
kubectl logs <POD_NAME> -n default -c istio-proxy -f
```

---

### 증상: 503 에러인데 업스트림 Pod 로그에는 요청이 없음

#### 원인
Envoy가 업스트림 Pod에 도달하기 전에 에러를 반환한 것. Access Log의 `RESPONSE_FLAGS` 확인 필요.

#### 해결 방법

```bash
# 에러가 발생한 Pod의 사이드카 로그에서 응답 플래그 확인
kubectl logs <CLIENT_POD> -n default -c istio-proxy | grep "503"

# 예시: "503 UH" → Endpoint 없음
# → Endpoint 상태 확인
istioctl proxy-config endpoint <CLIENT_POD> -n default | grep my-app

# 예시: "503 UF" → 연결 실패
# → mTLS 설정 확인
istioctl authn tls-check <CLIENT_POD>.default my-app.default.svc.cluster.local
```

---

## 4. 모니터링 및 확인

```bash
# 실시간 Access Log 확인
kubectl logs <POD_NAME> -n default -c istio-proxy -f

# 에러 응답만 필터링
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  grep -E '"response_code":"[45][0-9]{2}"'

# 응답 플래그가 있는 요청만 필터링 (UH, UF 등)
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  grep -v '"response_flags":"-"'

# 지연 500ms 이상인 요청 필터링 (JSON 포맷 기준)
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  jq 'select(.duration_ms | tonumber > 500)'

# 특정 경로 요청만 확인
kubectl logs <POD_NAME> -n default -c istio-proxy | grep '"/api/v1/health"'
```

---

## 5. TIP

- Access Log와 Jaeger Trace ID (`x_b3_traceid`)를 함께 기록하면 로그와 트레이스를 연결해 장애 원인 추적이 빠름
- `UPSTREAM_CLUSTER` 필드로 어떤 Cluster(서브셋)로 라우팅됐는지 확인 가능 — Canary 배포 검증에 유용
- EKS CloudWatch Logs와 연동 시 JSON 포맷 사용 권장 (필터 쿼리 활용)
- 고트래픽 환경에서 Access Log 전체 활성화 시 스토리지 비용 주의. Telemetry API의 `disabled: true`로 선택적 비활성화 권장
