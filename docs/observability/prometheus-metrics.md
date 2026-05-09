# Istio Prometheus 지표 심층 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio는 Envoy 사이드카를 통해 서비스 간 모든 트래픽을 자동으로 계측 (Instrumentation)해 Prometheus 지표로 노출함. 앱 코드 변경 없이 요청 수, 지연, 에러율, 연결 상태 등을 수집할 수 있음.

### 지표 수집 경로

```
Envoy Sidecar (:15090/stats/prometheus)
      │
      ▼
Prometheus (scrape)
      │
      ▼
Grafana / AlertManager
```

---

## 2. 핵심 표준 지표

Istio는 요청 레벨 지표 4종을 기본 제공함 (Standard Metrics).

### 요청 수 (istio_requests_total)

```promql
# 서비스별 초당 요청 수
rate(istio_requests_total{
  destination_service_name="my-app",
  destination_service_namespace="default"
}[1m])

# 에러율 (5xx)
sum(rate(istio_requests_total{
  destination_service_name="my-app",
  response_code=~"5.."
}[5m])) /
sum(rate(istio_requests_total{
  destination_service_name="my-app"
}[5m]))

# 소스 서비스별 요청 수 (누가 호출하는지)
sum by (source_app) (
  rate(istio_requests_total{
    destination_service_name="my-app"
  }[1m])
)
```

**주요 레이블:**

| 레이블 | 설명 |
|--------|------|
| `source_app` | 요청을 보낸 앱 이름 |
| `source_version` | 요청을 보낸 앱 버전 |
| `destination_service_name` | 목적지 서비스 이름 |
| `destination_version` | 목적지 Pod 버전 (version 레이블) |
| `response_code` | HTTP 응답 코드 |
| `response_flags` | Envoy 응답 플래그 (UF, UO 등) |
| `connection_security_policy` | `mutual_tls` 또는 `none` |
| `reporter` | `source` (클라이언트) 또는 `destination` (서버) |

---

### 요청 지연 (istio_request_duration_milliseconds)

```promql
# P50 / P99 지연 (목적지 기준)
histogram_quantile(0.99,
  sum by (le, destination_service_name) (
    rate(istio_request_duration_milliseconds_bucket{
      destination_service_name="my-app"
    }[5m])
  )
)

# 소스별 P99 지연 비교
histogram_quantile(0.99,
  sum by (le, source_app) (
    rate(istio_request_duration_milliseconds_bucket{
      destination_service_name="my-app"
    }[5m])
  )
)
```

---

### 요청 바이트 / 응답 바이트

```promql
# 평균 요청 크기
rate(istio_request_bytes_sum{destination_service_name="my-app"}[5m]) /
rate(istio_request_bytes_count{destination_service_name="my-app"}[5m])

# 평균 응답 크기
rate(istio_response_bytes_sum{destination_service_name="my-app"}[5m]) /
rate(istio_response_bytes_count{destination_service_name="my-app"}[5m])
```

---

### TCP 연결 지표 (TCP 서비스용)

```promql
# TCP 활성 연결 수
istio_tcp_connections_opened_total{destination_service_name="my-db"}

# TCP 전송 바이트
rate(istio_tcp_sent_bytes_total{destination_service_name="my-db"}[5m])
```

---

## 3. Envoy 내부 지표 (Raw Envoy Stats)

Istio 표준 지표 외에 Envoy 자체 지표 (`:15090/stats/prometheus`)에서 더 상세한 연결/큐 정보를 확인할 수 있음.

```bash
# Envoy 전체 지표 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15090/stats/prometheus | grep "envoy_cluster"
```

### 자주 활용하는 Envoy 지표

```promql
# Connection Pool 초과 횟수 (Circuit Breaker 동작)
envoy_cluster_upstream_cx_overflow{envoy_cluster_name=~".*my-app.*"}

# 활성 업스트림 연결 수
envoy_cluster_upstream_cx_active{envoy_cluster_name=~".*my-app.*"}

# 재시도 횟수
rate(envoy_cluster_upstream_rq_retry{envoy_cluster_name=~".*my-app.*"}[5m])

# Outlier Detection으로 제거된 Endpoint 수
envoy_cluster_outlier_detection_ejections_active{envoy_cluster_name=~".*my-app.*"}

# TLS 핸드셰이크 에러
envoy_listener_ssl_connection_error
```

---

## 4. 커스텀 지표 추가

Telemetry API로 기본 지표에 레이블을 추가하거나 새 지표를 정의할 수 있음.

### 커스텀 레이블 추가

```yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: custom-metrics
  namespace: default
spec:
  metrics:
    - providers:
        - name: prometheus
      overrides:
        - match:
            metric: REQUEST_COUNT
          tagOverrides:
            tenant_id:
              value: "request.headers['x-tenant-id'] | 'unknown'"
            api_version:
              value: "request.headers['x-api-version'] | 'v1'"
```

---

### 불필요한 지표 비활성화 (카디널리티 관리)

```yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: reduce-cardinality
  namespace: default
spec:
  metrics:
    - providers:
        - name: prometheus
      overrides:
        - match:
            metric: REQUEST_COUNT
          tagOverrides:
            destination_version:
              operation: REMOVE    # 불필요한 레이블 제거
```

---

## 5. 트러블슈팅

### 증상: Prometheus에서 Istio 지표가 수집되지 않음

#### 원인
Prometheus의 scrape 설정이 Istio 사이드카 포트(15090)를 대상으로 하지 않거나, 어노테이션이 없음

#### 해결 방법

```bash
# 1. 사이드카 지표 엔드포인트 직접 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15090/stats/prometheus | head -20

# 2. Pod 어노테이션 확인 (Prometheus scrape 설정)
kubectl get pod <POD_NAME> -n default -o yaml | grep -A 5 "annotations"
# prometheus.io/scrape: "true"
# prometheus.io/port: "15090"

# 3. Prometheus scrape 설정 확인
kubectl get configmap prometheus -n istio-system -o yaml | grep "job_name"

# 4. istiod 메트릭 엔드포인트 확인
kubectl exec -n istio-system deployment/istiod -- \
  curl -s http://localhost:15014/metrics | grep "pilot_" | head -10
```

---

### 증상: `reporter="source"`와 `reporter="destination"` 지표가 중복 수집됨

#### 원인
Istio는 요청을 클라이언트 사이드카(source)와 서버 사이드카(destination) 양쪽에서 모두 계측함. 의도된 동작이지만 합산 시 2배가 됨.

#### 해결 방법

```promql
# reporter 필터링으로 단일 뷰 구성
# destination 기준 (서버 관점): 더 정확한 에러/지연 측정
rate(istio_requests_total{
  reporter="destination",
  destination_service_name="my-app"
}[5m])

# source 기준 (클라이언트 관점): 재시도 포함 실제 시도 횟수
rate(istio_requests_total{
  reporter="source",
  destination_service_name="my-app"
}[5m])
```

---

## 6. 모니터링 및 확인

### 실무 알람 쿼리 모음

```promql
# 1. 에러율 5% 초과 알람
(
  sum(rate(istio_requests_total{
    reporter="destination",
    destination_service_name="my-app",
    response_code=~"5.."
  }[5m])) /
  sum(rate(istio_requests_total{
    reporter="destination",
    destination_service_name="my-app"
  }[5m]))
) > 0.05

# 2. P99 지연 1초 초과 알람
histogram_quantile(0.99,
  sum by (le) (
    rate(istio_request_duration_milliseconds_bucket{
      reporter="destination",
      destination_service_name="my-app"
    }[5m])
  )
) > 1000

# 3. Circuit Breaker 동작 감지
increase(envoy_cluster_upstream_cx_overflow{
  envoy_cluster_name=~".*my-app.*"
}[5m]) > 0
```

---

## 7. TIP

- `reporter="source"` 지표는 재시도를 포함한 실제 시도 횟수, `reporter="destination"`은 서버가 실제로 받은 횟수. 에러율 알람은 `destination` 기준 권장
- Istio 지표의 카디널리티가 높으면 Prometheus 메모리 사용량이 급증. `destination_version`, `source_version` 레이블을 Telemetry API로 제거하면 시리즈 수를 줄일 수 있음
- `response_flags` 레이블로 UF/UO/UT 등 Envoy 레벨 원인을 Prometheus에서 직접 쿼리 가능
- Istio 1.12+ Telemetry API를 사용하면 네임스페이스별로 지표 수집 설정을 다르게 적용 가능
