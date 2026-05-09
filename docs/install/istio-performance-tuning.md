# Istio 성능 튜닝 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio 사이드카는 편의성을 제공하는 대신 CPU/메모리 오버헤드와 레이턴시를 추가함. 이 문서는 사이드카 리소스 설정, istiod 튜닝, Envoy 동시성 설정 등 운영 환경에서 성능을 최적화하는 방법을 정리함.

### 오버헤드 기준치 (참고값)

| 항목 | 기본 오버헤드 |
|------|------------|
| 사이드카 메모리 | 50~100MB per Pod |
| 사이드카 CPU (idle) | 0.01~0.05 core |
| 추가 레이턴시 (P99) | 1~3ms (동일 노드 통신) |

---

## 2. 사이드카 리소스 설정

### 전역 리소스 설정 (MeshConfig)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |-
    defaultConfig:
      concurrency: 2             # Envoy 워커 스레드 수 (기본: 0 = CPU 코어 수)
      proxyStatsMatcher:         # 수집할 통계 필터링 (불필요한 통계 제거)
        inclusionRegexps:
          - ".*circuit_breakers.*"
          - ".*upstream_rq_retry.*"
          - ".*upstream_cx.*"
          - ".*ssl.*"
```

### Pod 레벨 리소스 오버라이드 (어노테이션)

```yaml
# Deployment spec.template.metadata.annotations
annotations:
  # 사이드카 리소스 요청/제한
  sidecar.istio.io/proxyCPU: "100m"
  sidecar.istio.io/proxyMemory: "128Mi"
  sidecar.istio.io/proxyCPULimit: "500m"
  sidecar.istio.io/proxyMemoryLimit: "256Mi"

  # 트래픽이 많은 서비스는 더 높은 리소스 할당
  # sidecar.istio.io/proxyCPU: "500m"
  # sidecar.istio.io/proxyMemory: "256Mi"
```

---

### Envoy 동시성 (Concurrency) 설정

Envoy 워커 스레드 수를 제어함. CPU 코어가 많은 노드에서 기본값(코어 수)을 사용하면 불필요한 스레드가 생성됨.

```yaml
# Pod별 concurrency 설정
annotations:
  proxy.istio.io/config: |
    concurrency: 2    # 워커 스레드 2개 (CPU 요청 200m에 적합)
```

**권장 concurrency 기준:**

| CPU Request | 권장 concurrency |
|------------|----------------|
| 100m 이하 | 1 |
| 100m ~ 500m | 2 |
| 500m ~ 1000m | 4 |
| 1000m 이상 | 기본값 (코어 수) |

---

## 3. Envoy 통계 최적화

기본적으로 Envoy는 수천 개의 통계를 수집함. 불필요한 통계를 필터링하면 메모리 사용량을 줄이고 Prometheus 수집 부하를 감소시킬 수 있음.

### 통계 필터링 (포함 목록 방식)

```yaml
# IstioOperator로 전역 설정
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
spec:
  meshConfig:
    defaultConfig:
      proxyStatsMatcher:
        inclusionRegexps:
          - ".*circuit_breakers.*"
          - ".*upstream_rq_(total|retry|timeout|pending).*"
          - ".*upstream_cx_(active|overflow|total).*"
          - ".*ssl\.(handshake|connection_error|session_reused).*"
          - ".*outlier_detection.*"
          - ".*rbac.*"
        exclusionRegexps:
          - ".*osconfig.*"      # 불필요한 통계 제거
```

---

### Telemetry API로 지표 카디널리티 감소

```yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: reduce-metric-cardinality
  namespace: istio-system
spec:
  metrics:
    - providers:
        - name: prometheus
      overrides:
        - match:
            metric: REQUEST_COUNT
          tagOverrides:
            destination_version:
              operation: REMOVE    # version 레이블 제거로 시리즈 수 감소
            source_version:
              operation: REMOVE
```

---

## 4. istiod 성능 튜닝

### istiod 리소스 설정

```yaml
# IstioOperator로 istiod 리소스 설정
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
spec:
  components:
    pilot:
      k8s:
        resources:
          requests:
            cpu: "500m"
            memory: "2Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
        hpaSpec:
          minReplicas: 2          # istiod HA 구성
          maxReplicas: 5
          metrics:
            - type: Resource
              resource:
                name: cpu
                target:
                  type: Utilization
                  averageUtilization: 60
```

---

### xDS 푸시 최적화

클러스터 규모가 크면 istiod의 xDS 푸시 부하가 높아짐.

```yaml
# istiod 환경 변수로 xDS 최적화
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  components:
    pilot:
      k8s:
        env:
          # 한 번에 푸시할 최대 연결 수 (대규모 클러스터에서 조절)
          - name: PILOT_PUSH_THROTTLE
            value: "100"
          # xDS 캐시 크기
          - name: PILOT_XDS_CACHE_SIZE
            value: "60000"
          # Endpoint 변경이 없으면 xDS 푸시 생략 (Delta xDS)
          - name: PILOT_ENABLE_EDS_DEBOUNCE
            value: "true"
```

---

## 5. 사이드카 선택적 주입

모든 Pod에 사이드카를 주입할 필요는 없음. 메시 내부 통신이 필요 없는 워크로드는 제외해 오버헤드를 줄임.

```yaml
# 특정 Pod만 사이드카 제외
metadata:
  annotations:
    sidecar.istio.io/inject: "false"    # 이 Pod는 사이드카 없이 실행
```

```yaml
# 배치/잡(Job) 워크로드는 사이드카 제외 권장
apiVersion: batch/v1
kind: Job
metadata:
  name: data-migration
  namespace: default
spec:
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"    # Job 완료 후 사이드카가 Pod 종료를 방해하지 않도록
    spec:
      containers:
        - name: migrator
          image: my-migrator:v1
```

---

### Sidecar 리소스로 Envoy가 보는 서비스 범위 제한

기본적으로 Envoy는 클러스터의 모든 서비스 설정을 수신함. `Sidecar` 리소스로 범위를 제한하면 istiod 푸시 크기와 Envoy 메모리를 절감함.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: my-app-sidecar
  namespace: default
spec:
  workloadSelector:
    labels:
      app: my-app
  egress:
    - hosts:
        - "default/downstream-service"    # 이 서비스만 알면 됨
        - "default/another-service"
        - "istio-system/*"               # 컨트롤 플레인 접근
  ingress:
    - port:
        number: 8080
        protocol: HTTP
        name: http
      defaultEndpoint: 127.0.0.1:8080
```

---

## 6. 트러블슈팅

### 증상: 사이드카 OOMKilled

#### 원인
트래픽이 많거나 서비스 수가 많아 Envoy 메모리 사용량이 한도 초과

#### 해결 방법

```bash
# 1. 현재 사이드카 메모리 사용량 확인
kubectl top pods -n default --containers | grep "istio-proxy"

# 2. Envoy 통계 수 확인 (많을수록 메모리 증가)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | wc -l

# 3. 메모리 한도 상향
# 어노테이션으로 특정 Pod만 조정
# sidecar.istio.io/proxyMemoryLimit: "512Mi"

# 4. Sidecar 리소스로 Envoy가 보는 서비스 수 제한
# (위 Sidecar 리소스 설정 참고)
```

---

### 증상: 사이드카 추가 후 레이턴시가 크게 증가함

#### 원인
Envoy 워커 스레드가 1개이거나 CPU 스로틀링 발생

#### 해결 방법

```bash
# 1. CPU 스로틀링 확인
kubectl top pods -n default --containers | grep "istio-proxy"

# CPU가 limit에 근접하면 스로틀링 발생
# → proxyCPULimit 상향 또는 concurrency 조정

# 2. Envoy 동시성 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/server_info | jq '.concurrency'

# 3. concurrency를 2 이상으로 설정
# 어노테이션: proxy.istio.io/config: '{"concurrency": 2}'
```

---

## 7. 모니터링 및 확인

```bash
# 사이드카 리소스 사용량 전체 확인
kubectl top pods -n default --containers | grep "istio-proxy" | sort -k4 -rn

# istiod 리소스 사용량
kubectl top pods -n istio-system

# xDS 푸시 지연 확인
kubectl exec -n istio-system deployment/istiod -- \
  curl -s http://localhost:15014/metrics | grep "pilot_xds_push_time"
```

### Prometheus 쿼리

```promql
# 사이드카 메모리 사용량 상위 Pod
topk(10,
  container_memory_working_set_bytes{
    container="istio-proxy"
  }
)

# istiod CPU 사용량
rate(container_cpu_usage_seconds_total{
  pod=~"istiod-.*",
  namespace="istio-system"
}[5m])

# xDS 푸시 P99 지연
histogram_quantile(0.99,
  rate(pilot_xds_push_time_bucket[5m])
)
```

---

## 8. TIP

- `concurrency: 0` (기본)은 노드의 전체 CPU 코어 수로 설정됨. c5.4xlarge (16코어)에 100m CPU를 요청한 사이드카가 16개 스레드를 만들면 오히려 비효율. `concurrency: 2` 고정 권장
- `Sidecar` 리소스는 대규모 클러스터에서 가장 효과적인 최적화 방법. 서비스 수가 500개 이상이면 적용 검토
- 통계 필터링으로 Prometheus 시리즈 수를 줄이면 Prometheus 메모리와 수집 시간도 함께 감소
- istiod는 최소 2개 레플리카로 HA 구성 권장. istiod 재시작 중에도 기존 사이드카는 마지막 설정으로 계속 동작하므로 트래픽 영향 없음
