# Grafana 대시보드 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio는 Grafana용 공식 대시보드를 제공하며, Prometheus에서 수집된 Istio 지표를 시각화함. 기본 대시보드를 활용하는 방법과 운영 목적에 맞는 커스텀 대시보드 구성 방법을 정리함.

---

## 2. Istio 공식 대시보드

### 설치

```bash
# Grafana + 공식 대시보드 설치 (Istio 샘플 애드온)
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/grafana.yaml

# Grafana UI 접근
kubectl port-forward -n istio-system svc/grafana 3000:3000
# http://localhost:3000 (기본 계정: admin / admin)
```

---

### 공식 대시보드 목록

| 대시보드 | 용도 | 주요 패널 |
|---------|------|---------|
| **Istio Mesh Dashboard** | 전체 메시 개요 | 전체 요청 수, 에러율, P50/P99 지연 |
| **Istio Service Dashboard** | 서비스별 상세 | 인바운드/아웃바운드 트래픽, 소스별 분류 |
| **Istio Workload Dashboard** | Pod(Workload)별 상세 | 인바운드/아웃바운드 세부 지표 |
| **Istio Control Plane Dashboard** | istiod 상태 | xDS 푸시 지연, 연결 수, 메모리 |
| **Istio Wasm Extension Dashboard** | WASM 필터 상태 | 필터별 실행 통계 |

---

### Istio Mesh Dashboard 핵심 패널

```
[Global Request Volume]    → 전체 초당 요청 수 (RPS)
[Global Success Rate]      → 전체 성공률 (비-5xx 비율)
[4xx / 5xx]               → 에러 요청 수
[P50 / P90 / P99 Latency] → 지연 분포
[Service]                  → 서비스별 RPS, 성공률, P99
```

---

## 3. 커스텀 대시보드 구성

### 서비스 Health Overview 패널

```
Panel 1: 초당 요청 수 (RPS)
Panel 2: 에러율 (5xx %)
Panel 3: P99 지연
Panel 4: Circuit Breaker 동작 횟수
```

**Panel 1: RPS**

```promql
sum(rate(istio_requests_total{
  reporter="destination",
  destination_service_name=~"$service",
  destination_service_namespace=~"$namespace"
}[1m]))
```

**Panel 2: 에러율**

```promql
sum(rate(istio_requests_total{
  reporter="destination",
  destination_service_name=~"$service",
  response_code=~"5.."
}[5m])) /
sum(rate(istio_requests_total{
  reporter="destination",
  destination_service_name=~"$service"
}[5m])) * 100
```

**Panel 3: P99 지연**

```promql
histogram_quantile(0.99,
  sum by (le) (
    rate(istio_request_duration_milliseconds_bucket{
      reporter="destination",
      destination_service_name=~"$service"
    }[5m])
  )
)
```

**Panel 4: Circuit Breaker (Connection Pool 초과)**

```promql
sum(rate(envoy_cluster_upstream_cx_overflow{
  envoy_cluster_name=~".*$service.*"
}[5m]))
```

---

### 대시보드 변수 설정

Grafana Dashboard Variables로 서비스/네임스페이스를 드롭다운으로 선택 가능하게 구성.

```
Variable: namespace
Type: Query
Query: label_values(istio_requests_total, destination_service_namespace)

Variable: service
Type: Query
Query: label_values(istio_requests_total{destination_service_namespace="$namespace"}, destination_service_name)
```

---

### Canary 배포 모니터링 대시보드

v1과 v2 트래픽을 함께 비교하는 패널 구성.

```promql
# v1 vs v2 RPS 비교
sum by (destination_version) (
  rate(istio_requests_total{
    reporter="destination",
    destination_service_name="my-app"
  }[1m])
)

# v1 vs v2 에러율 비교
sum by (destination_version) (
  rate(istio_requests_total{
    reporter="destination",
    destination_service_name="my-app",
    response_code=~"5.."
  }[5m])
) /
sum by (destination_version) (
  rate(istio_requests_total{
    reporter="destination",
    destination_service_name="my-app"
  }[5m])
) * 100

# v1 vs v2 P99 지연 비교
histogram_quantile(0.99,
  sum by (le, destination_version) (
    rate(istio_request_duration_milliseconds_bucket{
      reporter="destination",
      destination_service_name="my-app"
    }[5m])
  )
)
```

---

### istiod 컨트롤 플레인 모니터링

```promql
# xDS 푸시 지연 P99
histogram_quantile(0.99,
  sum by (le) (
    rate(pilot_xds_push_time_bucket[5m])
  )
)

# xDS 푸시 에러
rate(pilot_xds_write_timeout[5m])

# istiod에 연결된 Envoy 수
pilot_xds_pushes

# Envoy 버전 불일치 수
pilot_version_mismatch
```

---

## 4. 알람 (Alert) 설정

### Grafana Alert Rule 구성

```yaml
# Grafana Alert Rule 예시 (Grafana 8+ Unified Alerting)
# 에러율 5% 초과 시 알람

apiVersion: 1
groups:
  - orgId: 1
    name: istio-alerts
    folder: Istio
    interval: 1m
    rules:
      - uid: error-rate-alert
        title: "High Error Rate - my-app"
        condition: C
        data:
          - refId: A
            queryType: ""
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: prometheus
            model:
              expr: |
                sum(rate(istio_requests_total{
                  reporter="destination",
                  destination_service_name="my-app",
                  response_code=~"5.."
                }[5m])) /
                sum(rate(istio_requests_total{
                  reporter="destination",
                  destination_service_name="my-app"
                }[5m])) * 100
          - refId: C
            datasourceUid: "__expr__"
            model:
              type: threshold
              conditions:
                - evaluator:
                    type: gt
                    params: [5]    # 5% 초과 시 알람
```

---

## 5. 트러블슈팅

### 증상: Grafana에서 Istio 지표가 없음

#### 원인
Prometheus 데이터소스가 잘못 연결됐거나 Istio 지표가 Prometheus에 수집되지 않음

#### 해결 방법

```bash
# 1. Prometheus에서 Istio 지표 수집 확인
kubectl port-forward -n istio-system svc/prometheus 9090:9090
# http://localhost:9090/graph → istio_requests_total 쿼리

# 2. Grafana 데이터소스 확인
# Configuration → Data Sources → Prometheus URL 확인
# http://prometheus.istio-system:9090

# 3. 대시보드 임포트 확인 (ID로 임포트)
# Grafana → Import Dashboard → ID: 7639 (Istio Mesh Dashboard)
```

---

## 6. 모니터링 및 확인

```bash
# Grafana 접근
kubectl port-forward -n istio-system svc/grafana 3000:3000

# 공식 대시보드 ID 목록
# 7639: Istio Mesh Dashboard
# 7636: Istio Service Dashboard
# 7630: Istio Workload Dashboard
# 7645: Istio Control Plane Dashboard
```

---

## 7. TIP

- Grafana Dashboard JSON을 GitOps로 관리하면 대시보드 변경 이력 추적과 환경 간 동기화가 용이함
- 공식 대시보드는 Istio 버전마다 지표명이 바뀔 수 있음. 버전 업그레이드 후 대시보드도 함께 업데이트 필요
- 대시보드 패널에 `Threshold` (임계값 선)를 설정하면 정상 범위를 시각적으로 확인하기 쉬움 (예: P99 목표값 500ms 선)
- `reporter` 레이블 필터를 통일하지 않으면 source/destination 중복 계산으로 실제보다 2배의 RPS가 보일 수 있음. 대부분의 패널에서 `reporter="destination"` 사용 권장
