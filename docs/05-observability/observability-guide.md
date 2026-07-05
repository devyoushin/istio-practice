# Istio 관찰 가능성 (Observability) 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

Istio는 별도의 코드 수정 없이 세 가지 관찰 가능성 도구를 제공합니다.

| 도구 | 역할 | 설치 파일 |
|------|------|-----------|
| **Prometheus** | 메트릭 수집 (요청 수, 지연 시간, 오류율) | - |
| **Grafana** | 메트릭 시각화 대시보드 | - |
| **Jaeger** | 분산 트레이싱 (요청 흐름 추적) | [install-jaeger.md](./install-jaeger.md) |
| **Kiali** | 서비스 그래프 시각화 | [install-kiali.md](./install-kiali.md) |

---

## 2. Prometheus + Grafana 설치

### 1. Prometheus 설치

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/prometheus \
  --namespace istio-system \
  --set alertmanager.enabled=false \
  --set pushgateway.enabled=false
```

### 2. Grafana 설치

```bash
helm repo add grafana https://grafana.github.io/helm-charts

helm install grafana grafana/grafana \
  --namespace istio-system \
  --set datasources."datasources\.yaml".apiVersion=1 \
  --set datasources."datasources\.yaml".datasources[0].name=Prometheus \
  --set datasources."datasources\.yaml".datasources[0].type=prometheus \
  --set datasources."datasources\.yaml".datasources[0].url=http://prometheus-server.istio-system:80 \
  --set datasources."datasources\.yaml".datasources[0].access=proxy \
  --set datasources."datasources\.yaml".datasources[0].isDefault=true
```

### 3. Grafana 접속

```bash
# 초기 비밀번호 확인
kubectl get secret --namespace istio-system grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode

# 포트 포워딩
kubectl port-forward svc/grafana -n istio-system 3000:80

# 브라우저에서 http://localhost:3000 접속 (admin / 위 비밀번호)
```

### 4. Istio 대시보드 임포트

Grafana에서 Istio 공식 대시보드를 임포트합니다.

```
Grafana → Dashboards → Import → ID 입력
```

| 대시보드 | ID | 내용 |
|----------|----|------|
| Istio Mesh Dashboard | 7639 | 전체 메시 개요 |
| Istio Service Dashboard | 7636 | 서비스별 메트릭 |
| Istio Workload Dashboard | 7630 | Workload(Deployment)별 메트릭 |
| Istio Performance Dashboard | 11829 | Istio 자체 성능 |

---

## 3. 주요 Istio 메트릭

Prometheus에서 직접 쿼리할 수 있는 핵심 메트릭입니다.

### 요청 수 (RPS)

```promql
# 서비스별 초당 요청 수
sum(rate(istio_requests_total[1m])) by (destination_service_name)

# HTTP 상태 코드별 분류
sum(rate(istio_requests_total[1m])) by (destination_service_name, response_code)
```

### 오류율

```promql
# 5xx 오류율 (%)
sum(rate(istio_requests_total{response_code=~"5.."}[1m])) by (destination_service_name)
/
sum(rate(istio_requests_total[1m])) by (destination_service_name)
* 100
```

### 지연 시간 (P99)

```promql
# 서비스별 P99 지연 시간
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket[1m])) by (destination_service_name, le)
)
```

---

## 분산 트레이싱 (Jaeger)

### 트레이싱이 동작하려면

Istio는 자동으로 트레이싱 헤더를 생성하지만, 서비스 간 전파는 애플리케이션이 직접 해야 합니다.

**전파해야 할 헤더 목록**

```
x-request-id
x-b3-traceid
x-b3-spanid
x-b3-parentspanid
x-b3-sampled
x-b3-flags
b3
```

**Python 예시**

```python
TRACE_HEADERS = [
    'x-request-id', 'x-b3-traceid', 'x-b3-spanid',
    'x-b3-parentspanid', 'x-b3-sampled', 'x-b3-flags', 'b3'
]

def call_downstream(request):
    headers = {h: request.headers[h] for h in TRACE_HEADERS if h in request.headers}
    return requests.get("http://downstream-service/api", headers=headers)
```

### Jaeger 접속

```bash
kubectl port-forward svc/jaeger -n istio-system 16686:16686
# 브라우저에서 http://localhost:16686 접속
```

---

## Kiali 서비스 그래프

```bash
kubectl port-forward svc/kiali -n istio-system 20001:20001
# 브라우저에서 http://localhost:20001 접속
```

**Kiali에서 확인할 수 있는 것**

- 서비스 간 트래픽 흐름 (방향, 비율)
- mTLS 적용 여부 (자물쇠 아이콘)
- 오류율 (빨간색 엣지)
- VirtualService / DestinationRule 시각화
- Canary 트래픽 분할 비율 실시간 확인

---

## EKS에서 Prometheus 스크레이핑 설정

EKS 환경에서 Istio 메트릭이 수집되지 않는 경우, Prometheus에 Istio 스크레이핑 설정을 추가합니다.

```yaml
# prometheus-values.yaml
serverFiles:
  prometheus.yml:
    scrape_configs:
    - job_name: 'istio-mesh'
      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - istio-system
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: istio-telemetry;prometheus
```

```bash
helm upgrade prometheus prometheus-community/prometheus \
  --namespace istio-system \
  -f prometheus-values.yaml
```

---

## 참고

- [공식문서 - Observability](https://istio.io/latest/docs/tasks/observability/)
- [Grafana Istio 대시보드](https://grafana.com/grafana/dashboards/?search=istio)
- [공식문서 - 분산 트레이싱](https://istio.io/latest/docs/tasks/observability/distributed-tracing/)
