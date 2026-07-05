# Rate Limiting 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio에서 Rate Limiting은 두 가지 방식으로 구현함.

| 방식 | 구현 | 특징 |
|------|------|------|
| **로컬 Rate Limit** | EnvoyFilter (각 사이드카) | 설정 단순, Pod 단위 적용 |
| **글로벌 Rate Limit** | 외부 Rate Limit 서비스 + EnvoyFilter | 클러스터 전체 통합 제한 |

로컬 Rate Limit는 Pod 수 × 설정값이 실제 허용량. 전체 클러스터 단위 제한이 필요하면 글로벌 Rate Limit 서비스를 별도 배포해야 함.

---

## 2. 로컬 Rate Limit (Local Rate Limit)

### 기본 설정 — 인바운드 트래픽 제한

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: local-rate-limit
  namespace: default
spec:
  workloadSelector:
    labels:
      app: my-app
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: "envoy.filters.network.http_connection_manager"
              subFilter:
                name: "envoy.filters.http.router"
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.local_ratelimit
          typedConfig:
            "@type": type.googleapis.com/udpa.type.v1.TypedStruct
            type_url: type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
            value:
              stat_prefix: http_local_rate_limiter
              token_bucket:
                max_tokens: 100           # 버킷 최대 토큰 수
                tokens_per_fill: 100      # 리필 시 추가 토큰 수
                fill_interval: 60s        # 리필 주기
              filter_enabled:
                runtime_key: local_rate_limit_enabled
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              filter_enforced:
                runtime_key: local_rate_limit_enforced
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              response_headers_to_add:
                - append: false
                  header:
                    key: x-local-rate-limit
                    value: "true"
```

---

### 경로별 Rate Limit 설정

```yaml
# VirtualHost 레벨에서 경로별 다른 한도 설정
- applyTo: VIRTUAL_HOST
  match:
    context: SIDECAR_INBOUND
    routeConfiguration:
      vhost:
        name: "inbound|http|8080"
  patch:
    operation: MERGE
    value:
      rate_limits:
        - actions:
            - request_headers:
                header_name: ":path"
                descriptor_key: path
      typed_per_filter_config:
        envoy.filters.http.local_ratelimit:
          "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
          stat_prefix: http_local_rate_limiter
          token_bucket:
            max_tokens: 10            # /api/expensive 경로는 분당 10회
            tokens_per_fill: 10
            fill_interval: 60s
```

---

### 429 응답 헤더 커스터마이징

```yaml
# 한도 초과 시 응답 커스터마이징
response_headers_to_add:
  - append: false
    header:
      key: x-ratelimit-limit
      value: "100"
  - append: false
    header:
      key: x-ratelimit-remaining
      value: "0"
  - append: false
    header:
      key: retry-after
      value: "60"
status: 429                           # 기본값: 429
```

---

## 3. 글로벌 Rate Limit (Global Rate Limit)

여러 Pod에 걸쳐 클러스터 전체 요청 수를 제한할 때 사용. 외부 Rate Limit 서비스 (06-envoy-deep-dive/ratelimit) 배포 필요.

### Rate Limit 서비스 배포

```yaml
# Redis (Rate Limit 서비스의 카운터 저장소)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: istio-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7
          ports:
            - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: istio-system
spec:
  selector:
    app: redis
  ports:
    - port: 6379
```

```yaml
# Rate Limit 서비스 설정 (ConfigMap)
apiVersion: v1
kind: ConfigMap
metadata:
  name: ratelimit-config
  namespace: istio-system
data:
  config.yaml: |
    domain: my-app-ratelimit
    descriptors:
      - key: remote_address
        rate_limit:
          unit: minute
          requests_per_unit: 100    # IP당 분당 100회
      - key: header_match
        value: premium
        rate_limit:
          unit: minute
          requests_per_unit: 1000   # premium 헤더: 분당 1000회
```

```yaml
# Rate Limit 서비스 Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ratelimit
  namespace: istio-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ratelimit
  template:
    metadata:
      labels:
        app: ratelimit
    spec:
      containers:
        - name: ratelimit
          image: envoyproxy/ratelimit:master
          env:
            - name: REDIS_SOCKET_TYPE
              value: tcp
            - name: REDIS_URL
              value: redis:6379
            - name: RUNTIME_ROOT
              value: /data
            - name: RUNTIME_SUBDIRECTORY
              value: ratelimit
            - name: RUNTIME_IGNOREDOTFILES
              value: "true"
            - name: LOG_LEVEL
              value: debug
          volumeMounts:
            - name: config
              mountPath: /data/ratelimit/config
      volumes:
        - name: config
          configMap:
            name: ratelimit-config
---
apiVersion: v1
kind: Service
metadata:
  name: ratelimit
  namespace: istio-system
spec:
  selector:
    app: ratelimit
  ports:
    - port: 8081
      name: http
    - port: 8080
      name: grpc
```

---

### EnvoyFilter로 글로벌 Rate Limit 연결

```yaml
# Rate Limit 서비스를 Envoy에 연결
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: filter-ratelimit
  namespace: istio-system
spec:
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: "envoy.filters.network.http_connection_manager"
              subFilter:
                name: "envoy.filters.http.router"
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.ratelimit
          typedConfig:
            "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
            domain: my-app-ratelimit
            failure_mode_deny: false       # Rate Limit 서비스 장애 시 통과(false) 또는 차단(true)
            rate_limit_service:
              grpc_service:
                envoy_grpc:
                  cluster_name: rate_limit_cluster
              transport_api_version: V3
```

---

## 4. 트러블슈팅

### 증상: Rate Limit 설정 후 모든 요청이 429

#### 원인
`max_tokens`와 `tokens_per_fill`이 너무 낮거나 `fill_interval`이 너무 길게 설정됨

#### 해결 방법

```bash
# 1. 현재 Rate Limit 통계 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "local_rate_limit"

# http_local_rate_limiter.rate_limited: 제한된 요청 수
# http_local_rate_limiter.ok: 통과된 요청 수

# 2. Rate Limit 설정 일시 비활성화
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/runtime_modify?local_rate_limit_enabled=0"

# 3. EnvoyFilter 임시 삭제로 원복
kubectl delete envoyfilter local-rate-limit -n default
```

---

### 증상: 글로벌 Rate Limit 서비스 장애 시 전체 트래픽 차단

#### 원인
`failure_mode_deny: true`로 설정됨

#### 해결 방법

```yaml
# failure_mode_deny를 false로 변경 (Rate Limit 서비스 장애 시 통과)
failure_mode_deny: false
```

---

## 5. 모니터링 및 확인

```bash
# 로컬 Rate Limit 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "local_rate_limit"

# rate_limited: 제한된 요청 수 (429 반환)
# ok: 정상 통과된 요청 수

# Access Log에서 429 필터링
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  jq 'select(.response_code == "429")'
```

### Prometheus 쿼리

```promql
# Rate Limit 발동률
rate(istio_requests_total{
  response_code="429",
  destination_service_name="my-app"
}[5m])

# 정상 vs Rate Limited 비율
sum(rate(istio_requests_total{destination_service_name="my-app",response_code="429"}[5m])) /
sum(rate(istio_requests_total{destination_service_name="my-app"}[5m]))
```

---

## 6. TIP

- 로컬 Rate Limit의 실제 클러스터 허용량 = `max_tokens × Pod 수`. HPA로 Pod가 늘어나면 자동으로 허용량도 증가함. 절대적 한도가 필요하면 글로벌 Rate Limit 사용
- `failure_mode_deny: false` 설정을 권장. Rate Limit 서비스가 SPOF가 되지 않도록 HA 구성 또는 fail-open 설정 필수
- 로컬 Rate Limit의 토큰 버킷은 각 Envoy 인스턴스 메모리에서 관리되므로 재시작하면 리셋됨
- Gateway(인그레스)에 Rate Limit을 적용하면 내부 서비스 보호에 효과적. 각 마이크로서비스 사이드카에도 적용하면 내부 남용도 방지 가능
