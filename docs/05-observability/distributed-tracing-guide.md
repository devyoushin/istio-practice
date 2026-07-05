# 분산 트레이싱 심층 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

분산 트레이싱 (Distributed Tracing)은 마이크로서비스 환경에서 요청이 여러 서비스를 거치며 처리되는 전체 흐름을 단일 Trace로 연결해 시각화하는 기술임. Istio는 Envoy 사이드카가 자동으로 트레이싱 헤더를 수집하지만, **서비스 간 헤더 전파 (Context Propagation)는 앱 코드가 직접 수행**해야 함.

### 핵심 개념

| 개념 | 설명 |
|------|------|
| **Trace** | 요청 하나의 전체 흐름 (Span들의 집합) |
| **Span** | 하나의 서비스에서 처리된 단위 작업 |
| **Trace ID** | Trace 전체를 식별하는 고유 ID |
| **Parent Span ID** | 호출한 서비스의 Span ID |
| **Sampling Rate** | 전체 요청 중 트레이싱할 비율 |

---

## 2. 트레이싱 헤더

### B3 헤더 (Zipkin/Jaeger 기본)

Istio 기본 트레이싱 헤더 형식. 앱이 인바운드 요청에서 헤더를 읽고 아웃바운드 요청에 그대로 전달해야 Trace가 연결됨.

| 헤더 | 필수 | 설명 |
|------|------|------|
| `x-request-id` | 필수 | Envoy가 자동 생성하는 요청 식별자 |
| `x-b3-traceid` | 필수 | Trace 전체 ID (64bit 또는 128bit hex) |
| `x-b3-spanid` | 필수 | 현재 Span ID |
| `x-b3-parentspanid` | 권장 | 부모 Span ID (루트 Span은 없음) |
| `x-b3-sampled` | 권장 | 샘플링 여부 (`1`: 수집, `0`: 수집 안 함) |

### W3C Trace Context 헤더 (표준)

```
traceparent: 00-<trace-id>-<parent-id>-<flags>
tracestate:  vendor-specific
```

Istio 1.12+에서 W3C Trace Context를 기본 지원.

---

### 헤더 전파 구현 (앱 코드)

**Envoy는 자동으로 헤더를 생성하지만, 서비스 A → B → C 흐름에서 B가 헤더를 C로 전달하지 않으면 Trace가 끊김.**

#### Python 예시

```python
import requests

TRACE_HEADERS = [
    'x-request-id',
    'x-b3-traceid',
    'x-b3-spanid',
    'x-b3-parentspanid',
    'x-b3-sampled',
    'x-b3-flags',
    'b3',
    'traceparent',
    'tracestate',
]

def forward_headers(incoming_headers: dict) -> dict:
    """인바운드 요청에서 트레이싱 헤더를 추출해 아웃바운드 요청에 전달"""
    return {
        key: value
        for key, value in incoming_headers.items()
        if key.lower() in TRACE_HEADERS
    }

# FastAPI 예시
from fastapi import Request
import httpx

@app.get("/api/data")
async def get_data(request: Request):
    headers = forward_headers(dict(request.headers))
    async with httpx.AsyncClient() as client:
        response = await client.get(
            "http://downstream-service:8080/data",
            headers=headers    # 헤더 전달 필수
        )
    return response.json()
```

#### Go 예시

```go
func forwardHeaders(r *http.Request, outReq *http.Request) {
    traceHeaders := []string{
        "x-request-id", "x-b3-traceid", "x-b3-spanid",
        "x-b3-parentspanid", "x-b3-sampled", "x-b3-flags",
        "traceparent", "tracestate",
    }
    for _, h := range traceHeaders {
        if v := r.Header.Get(h); v != "" {
            outReq.Header.Set(h, v)
        }
    }
}
```

---

## 3. 샘플링 설정

전체 트래픽을 트레이싱하면 Jaeger/Zipkin에 과부하가 발생함. 샘플링 비율 조정이 필수.

### istiod 전역 샘플링 설정

```yaml
# istio ConfigMap 수정
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |-
    defaultConfig:
      tracing:
        sampling: 1.0        # 1%만 샘플링 (운영 환경 권장: 0.1 ~ 1.0)
        zipkin:
          address: jaeger-collector.istio-system:9411
```

```bash
kubectl apply -f istio-configmap.yaml -n istio-system
# 변경 사항은 새 Pod에만 적용됨 (재시작 필요)
kubectl rollout restart deployment/my-app -n default
```

---

### Telemetry API로 네임스페이스별 샘플링 설정

```yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: tracing-config
  namespace: default
spec:
  tracing:
    - providers:
        - name: jaeger          # MeshConfig에 등록된 provider 이름
      randomSamplingPercentage: 5.0   # 5% 샘플링
      disableSpanReporting: false
```

---

### 헤더로 특정 요청 강제 샘플링

```bash
# x-b3-sampled: 1 헤더로 이 요청은 반드시 트레이싱
curl -H "x-b3-sampled: 1" http://my-app:8080/api/debug

# 장애 재현 시 특정 요청만 강제 샘플링해 Trace 확인
```

---

## 4. 트레이싱 백엔드 설정

### Jaeger 연동 (추천)

```yaml
# MeshConfig에 Jaeger provider 등록
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |-
    extensionProviders:
      - name: jaeger
        opentelemetry:
          service: jaeger-collector.istio-system.svc.cluster.local
          port: 4317            # OTLP gRPC 포트
```

```yaml
# Telemetry API로 적용
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: mesh-tracing
  namespace: istio-system     # 전체 메시 적용
spec:
  tracing:
    - providers:
        - name: jaeger
      randomSamplingPercentage: 1.0
```

---

### Trace와 로그 연결

Access Log에 Trace ID를 포함시키면 로그에서 Trace로 바로 이동 가능.

```yaml
# Access Log JSON 포맷에 trace_id 추가
accessLogFormat: |
  {
    "trace_id": "%REQ(X-B3-TRACEID)%",
    "span_id": "%REQ(X-B3-SPANID)%",
    "timestamp": "%START_TIME%",
    "response_code": "%RESPONSE_CODE%",
    "duration_ms": "%DURATION%",
    "path": "%REQ(:PATH)%"
  }
```

```bash
# Access Log에서 특정 Trace ID 요청 추적
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  jq 'select(.trace_id == "<TRACE_ID>")'
```

---

## 5. 트러블슈팅

### 증상: Jaeger에서 Trace가 단절됨 (Span이 한 서비스에서만 보임)

#### 원인
중간 서비스가 트레이싱 헤더를 다음 서비스로 전달하지 않음

#### 해결 방법

```bash
# 1. 특정 Pod로 들어오는 요청에 트레이싱 헤더가 있는지 확인
# Envoy debug 로그 활성화
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/logging?http=debug"

kubectl logs <POD_NAME> -n default -c istio-proxy | grep "x-b3-traceid"

# 2. 앱 컨테이너가 아웃바운드 요청에 헤더를 포함하는지 확인
# 앱 로그에서 아웃바운드 헤더 확인

# 3. 로그 레벨 원복
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/logging?level=warning"
```

---

### 증상: Jaeger에 Trace가 전혀 수집되지 않음

#### 원인
샘플링 비율이 0이거나 Jaeger collector 주소가 잘못됨

#### 해결 방법

```bash
# 1. 현재 샘플링 설정 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" | contains("BootstrapConfigDump")) |
      .bootstrap.tracing'

# 2. Jaeger collector 연결 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "jaeger"

# 3. x-b3-sampled: 1 헤더로 강제 샘플링 후 Jaeger 확인
curl -H "x-b3-sampled: 1" http://my-app:8080/api/test
```

---

## 6. 모니터링 및 확인

```bash
# Jaeger UI에서 Trace 조회
kubectl port-forward -n istio-system svc/jaeger-query 16686:16686
# http://localhost:16686

# 특정 서비스의 최근 Trace 확인
# Jaeger UI → Search → Service: my-app → Find Traces

# 샘플링 비율 확인
istioctl proxy-config bootstrap <POD_NAME> -n default | grep -A 5 "tracing"
```

---

## 7. TIP

- 운영 환경 샘플링 비율은 1% 이하 권장. 트래픽이 많은 서비스에서 100% 샘플링하면 Jaeger 과부하 및 Envoy 오버헤드 발생
- OpenTelemetry SDK를 앱에 도입하면 헤더 전파를 자동화하고 앱 내부 Span도 추가 가능 (Istio Envoy Span과 병합됨)
- Trace ID를 앱 에러 로그에도 출력하면 로그와 Trace를 연결해 근본 원인 추적이 빠름
- `x-request-id` 헤더는 Trace ID와 별개로 Envoy가 각 요청에 부여하는 UUID. Access Log와 Trace를 연결하는 데 사용
