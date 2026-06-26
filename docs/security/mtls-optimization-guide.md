# Istio mTLS 최적화 가이드

> **작성일**: 2026-06-26
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

mTLS(Mutual TLS) 최적화는 암호화를 끄는 작업이 아니라, **필요한 구간은 STRICT로 강제하고, 불필요한 예외·중복 설정·과도한 Envoy 설정 전파를 줄이는 작업**이다.

Istio의 mTLS는 크게 두 설정으로 나뉜다.

| 리소스 | 방향 | 역할 |
|---|---|---|
| 피어 인증 (PeerAuthentication) | Inbound | 서버 워크로드가 어떤 트래픽을 받을지 결정 |
| 대상 규칙 (DestinationRule) | Outbound | 클라이언트 사이드카가 목적지로 어떤 TLS 모드로 보낼지 결정 |

최적화의 핵심은 아래 순서다.

| 단계 | 목표 | 결과 |
|---|---|---|
| 1 | `PERMISSIVE` 잔존 구간 식별 | 평문 허용 구간 축소 |
| 2 | 네임스페이스 단위 `STRICT` 적용 | 정책 단순화 |
| 3 | 불필요한 `DestinationRule.tls` 제거 또는 정리 | Auto mTLS 오동작·충돌 방지 |
| 4 | 예외 포트만 `portLevelMtls`로 분리 | 전체 서비스 `DISABLE` 방지 |
| 5 | Sidecar/설정 스코프 축소 | Envoy 메모리·xDS 설정량 감소 |
| 6 | 핸드셰이크·연결 재사용·인증서 갱신 관측 | 성능 병목 조기 탐지 |

---

## 2. 설명

### 2.1 기본 전략

Istio는 `DestinationRule`에 TLS 설정이 명시되지 않은 경우 Auto mTLS를 통해 메시 내부 워크로드에는 Istio mTLS를 자동 사용한다. 따라서 모든 서비스마다 `trafficPolicy.tls.mode: ISTIO_MUTUAL`을 반복 선언하는 방식은 관리 비용을 늘리고, 일부 서비스 예외 처리 시 충돌 지점을 만들기 쉽다.

운영 기준은 아래처럼 잡는다.

| 상황 | 권장 설정 | 이유 |
|---|---|---|
| 메시 내부 서비스 간 통신 | `PeerAuthentication: STRICT`, `DestinationRule.tls` 생략 또는 필요한 서비스만 `ISTIO_MUTUAL` | Auto mTLS 활용, 설정 중복 축소 |
| 마이그레이션 중인 네임스페이스 | `PeerAuthentication: PERMISSIVE` | 사이드카 미주입 워크로드와 공존 |
| 외부 서비스로 TLS Origination 필요 | `DestinationRule.tls.mode: SIMPLE` 또는 `MUTUAL` | 외부 서버 인증서 검증과 클라이언트 인증서 사용 |
| 특정 포트만 평문 필요 | `portLevelMtls`로 해당 workload port만 `DISABLE` | 서비스 전체 평문 허용 방지 |
| VM, legacy, batch 등 사이드카 없는 호출자 존재 | 네임스페이스 `PERMISSIVE` 유지 후 호출자부터 메시 편입 | `STRICT` 전환 시 즉시 장애 방지 |

### 2.2 `PERMISSIVE`를 줄이고 `STRICT`를 기본값으로 사용

`PERMISSIVE`는 mTLS와 평문을 모두 허용하므로 마이그레이션에는 유용하지만, 운영 정상 상태의 기본값으로 남기면 평문 우회 경로가 유지된다. 네임스페이스별로 평문 호출자가 없는지 확인한 뒤 `STRICT`로 전환한다.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: default
spec:
  mtls:
    mode: STRICT
```

메시 전체에 적용할 때는 root namespace인 `istio-system`에 배치한다. 단, root namespace의 selector 기반 `PeerAuthentication`은 기대와 다르게 동작하기 쉬우므로 워크로드별 예외는 실제 애플리케이션 네임스페이스에 둔다.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

### 2.3 Auto mTLS를 우선 사용하고 `DestinationRule`은 필요한 곳만 명시

메시 내부 서비스에 대해 아래와 같은 `DestinationRule`을 모든 서비스마다 만드는 방식은 피한다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app.default.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

위 설정 자체가 틀린 것은 아니다. 다만 수백 개 서비스에 반복되면 아래 문제가 생긴다.

| 문제 | 영향 |
|---|---|
| 서비스별 DestinationRule 증가 | istiod 처리량, Envoy xDS 설정량 증가 |
| 예외 서비스와 공통 템플릿 충돌 | 외부 서비스 또는 legacy 서비스에 잘못된 mTLS 적용 |
| `DISABLE` 예외가 넓게 적용됨 | 특정 포트 예외가 서비스 전체 평문 허용으로 번짐 |

권장 패턴은 다음과 같다.

| 대상 | DestinationRule TLS 설정 |
|---|---|
| 일반적인 메시 내부 서비스 | 생략하여 Auto mTLS 사용 |
| subset, connectionPool, outlierDetection이 필요한 서비스 | 필요한 trafficPolicy만 선언하고 TLS는 가능하면 생략 |
| 외부 HTTPS 서비스 | `SIMPLE` 또는 `MUTUAL` 명시 |
| Istio 인증서를 강제해야 하는 특수 서비스 | `ISTIO_MUTUAL` 명시 |

### 2.4 포트 예외는 서비스 전체가 아니라 workload port 단위로 제한

헬스체크, metrics, legacy plaintext 포트 때문에 전체 서비스를 `PERMISSIVE` 또는 `DISABLE`로 낮추면 애플리케이션 포트까지 평문 허용된다. 예외는 `portLevelMtls`로 해당 workload port에만 둔다.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: my-app-port-exception
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  mtls:
    mode: STRICT
  portLevelMtls:
    15020:
      mode: DISABLE
```

`portLevelMtls`의 포트는 Kubernetes Service port가 아니라 컨테이너가 실제로 listen하는 workload port 기준이다. Service port와 targetPort가 다르면 targetPort 기준으로 작성한다.

### 2.5 외부 서비스 TLS Origination과 내부 mTLS를 분리

외부 HTTPS API 호출은 Istio mTLS가 아니라 일반 TLS(TLS) Origination이다. 외부 서비스에 `ISTIO_MUTUAL`을 적용하면 상대 서버가 Istio 인증서를 이해하지 못해 핸드셰이크가 실패한다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-api
  namespace: default
spec:
  hosts:
    - api.example.com
  ports:
    - number: 443
      name: https
      protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: external-api-tls
  namespace: default
spec:
  host: api.example.com
  trafficPolicy:
    tls:
      mode: SIMPLE
      sni: api.example.com
```

### 2.6 Sidecar 리소스로 설정 범위를 줄임

mTLS 자체의 암호화 비용보다 운영에서 더 자주 문제가 되는 부분은 Envoy가 들고 있는 listener, cluster, endpoint 설정량이다. 네임스페이스 또는 워크로드가 실제 호출하는 서비스만 보도록 `Sidecar` 리소스를 적용하면 Envoy 메모리와 xDS push 부담을 줄인다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: default
  namespace: default
spec:
  egress:
    - hosts:
        - "./*"
        - "istio-system/*"
```

위 설정은 `default` 네임스페이스 워크로드가 같은 네임스페이스 서비스와 `istio-system` 서비스만 보도록 제한한다. 다른 네임스페이스 서비스 호출이 필요한 경우 해당 네임스페이스를 명시적으로 추가한다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: my-app
  namespace: default
spec:
  workloadSelector:
    labels:
      app: my-app
  egress:
    - hosts:
        - "./*"
        - "payments/*"
        - "istio-system/*"
```

### 2.7 연결 재사용과 커넥션 풀 조정

mTLS 핸드셰이크는 새 연결을 만들 때 비용이 발생한다. 요청마다 새 TCP/TLS 연결을 만들면 Envoy CPU와 upstream connect latency가 증가한다. HTTP keep-alive, HTTP/2, connection pool을 활용해 연결 재사용을 유지한다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-connection-pool
  namespace: default
spec:
  host: my-app.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 200
        connectTimeout: 3s
      http:
        http2MaxRequests: 1000
        maxRequestsPerConnection: 100
```

값은 서비스 QPS, Pod 수, upstream 처리량 기준으로 산정한다. 낮게 잡으면 `UO`(Upstream Overflow), `503`이 증가하고, 높게 잡으면 backend connection 폭증이 발생한다.

### 2.8 인증서 갱신과 istiod 부하 확인

mTLS 최적화에서 인증서 만료와 SDS(Secret Discovery Service) 전달 지연은 성능 문제처럼 보이는 장애를 만든다. 대량 Pod 재시작, 대규모 롤아웃, istiod CPU 부족 시 인증서 발급·갱신 지연이 발생한다.

```bash
# istiod 상태와 프록시 동기화 상태 확인
istioctl proxy-status -n istio-system

# 특정 Pod의 secret/SDS 상태 확인
istioctl proxy-config secret <POD_NAME> -n default

# 특정 Pod의 cluster TLS 설정 확인
istioctl proxy-config cluster <POD_NAME> -n default --fqdn my-app.default.svc.cluster.local
```

인증서 갱신 문제는 [mTLS 인증서 라이프사이클](./mtls-certificate-lifecycle.md)과 [mTLS 디버그 가이드](./mtls-debug-guide.md)를 함께 확인한다.

---

## 3. 트러블슈팅

### 증상
- `STRICT` 적용 후 특정 호출만 `503 UF`, `upstream connect error`, `connection reset` 발생

### 원인
- 호출자 Pod에 사이드카가 없거나, 호출자가 메시 외부에 있어 mTLS 클라이언트 인증서를 제시하지 못함

### 해결 방법

```bash
# 호출자/수신자 Pod에 istio-proxy 컨테이너가 있는지 확인
kubectl get pod <CLIENT_POD> -n default -o jsonpath='{.spec.containers[*].name}'
kubectl get pod <SERVER_POD> -n default -o jsonpath='{.spec.containers[*].name}'

# 네임스페이스 injection 라벨 확인
kubectl get namespace default --show-labels

# Istio 설정 분석
istioctl analyze -n default
```

호출자에 사이드카를 주입하거나, 마이그레이션 기간 동안 해당 네임스페이스만 `PERMISSIVE`로 되돌린다. 장기 예외는 서비스 전체가 아니라 workload selector 또는 port 단위로 제한한다.

---

### 증상
- 외부 HTTPS API 호출이 `TLS error`, `CERTIFICATE_VERIFY_FAILED`, `UF`로 실패함

### 원인
- 외부 서비스에 `ISTIO_MUTUAL`을 적용했거나, ServiceEntry/DestinationRule의 host와 SNI가 맞지 않음

### 해결 방법

```bash
# 외부 서비스 DestinationRule 확인
kubectl get destinationrule external-api-tls -n default -o yaml

# Envoy cluster TLS 설정 확인
istioctl proxy-config cluster <POD_NAME> -n default --fqdn api.example.com
```

외부 HTTPS 서비스는 `SIMPLE`, 외부 mTLS 서비스는 `MUTUAL`, 메시 내부 Istio 인증서는 `ISTIO_MUTUAL`로 분리한다.

---

### 증상
- mTLS 적용 후 CPU 사용량과 p99 latency가 증가함

### 원인
- 짧은 연결이 과도하게 생성되어 TLS 핸드셰이크가 반복되거나, Envoy가 과도한 telemetry/configuration을 처리함

### 해결 방법

```bash
# Envoy upstream 연결/요청 통계 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E 'upstream_cx_|ssl.handshake|downstream_cx'

# 프록시가 들고 있는 cluster 수 확인
istioctl proxy-config cluster <POD_NAME> -n default | wc -l

# listener 수 확인
istioctl proxy-config listener <POD_NAME> -n default | wc -l
```

HTTP keep-alive를 끄는 클라이언트 설정을 제거하고, 필요한 서비스에 connection pool을 적용한다. 네임스페이스 간 의존성이 명확한 서비스는 `Sidecar` 리소스로 설정 범위를 축소한다.

---

### 증상
- 특정 포트만 평문으로 열어야 하는데 서비스 전체 mTLS를 낮추고 있음

### 원인
- Service port와 workload port 구분 없이 `PeerAuthentication` 전체 모드를 `PERMISSIVE` 또는 `DISABLE`로 낮춤

### 해결 방법

```bash
# Service port와 targetPort 확인
kubectl get service my-app -n default -o yaml

# Pod containerPort 확인
kubectl get pod <POD_NAME> -n default -o jsonpath='{.spec.containers[*].ports}'
```

`portLevelMtls`를 사용해 필요한 workload port만 예외 처리한다.

---

## 4. 모니터링 및 확인

### 4.1 정책 적용 상태 확인

```bash
# PeerAuthentication 목록 확인
kubectl get peerauthentication -A

# DestinationRule TLS 설정 확인
kubectl get destinationrule -A -o yaml | grep -E 'name:|namespace:|mode:'

# 전체 Istio 설정 분석
istioctl analyze -A

# 프록시 동기화 상태 확인
istioctl proxy-status -n istio-system
```

### 4.2 mTLS 실제 적용 확인

```bash
# Pod 관점에서 mTLS/AuthorizationPolicy 상태 요약
istioctl x describe pod <POD_NAME> -n default

# Secret/SDS 인증서 상태 확인
istioctl proxy-config secret <POD_NAME> -n default

# 목적지 cluster의 TLS 설정 확인
istioctl proxy-config cluster <POD_NAME> -n default --fqdn my-app.default.svc.cluster.local
```

### 4.3 Prometheus 확인 쿼리

```promql
# 워크로드별 요청 성공률
sum(rate(istio_requests_total{reporter="destination",destination_workload="my-app",response_code!~"5.."}[5m]))
/
sum(rate(istio_requests_total{reporter="destination",destination_workload="my-app"}[5m]))
```

```promql
# mTLS 전환 후 503 증가 여부
sum by (destination_workload, response_code) (
  rate(istio_requests_total{reporter="destination",response_code="503"}[5m])
)
```

```promql
# Envoy 메모리 사용량
container_memory_working_set_bytes{
  namespace="default",
  container="istio-proxy"
}
```

```promql
# Envoy CPU 사용량
rate(container_cpu_usage_seconds_total{
  namespace="default",
  container="istio-proxy"
}[5m])
```

### 4.4 최적화 전후 비교 지표

| 지표 | 확인 방법 | 판단 기준 |
|---|---|---|
| 5xx 비율 | `istio_requests_total` | `STRICT` 전환 직후 증가 여부 |
| p95/p99 latency | Grafana Istio Workload Dashboard | 핸드셰이크·커넥션 풀 변경 후 증가 여부 |
| Envoy CPU | `container_cpu_usage_seconds_total{container="istio-proxy"}` | 연결 수 증가와 함께 상승하는지 확인 |
| Envoy memory | `container_memory_working_set_bytes{container="istio-proxy"}` | Sidecar scope 적용 전후 비교 |
| cluster/listener 수 | `istioctl proxy-config` | 불필요한 설정 전파 축소 확인 |
| SDS 상태 | `istioctl proxy-config secret` | 인증서 만료·갱신 실패 확인 |

---

## 5. TIP

- mTLS 최적화는 `STRICT`를 포기하는 작업이 아님. 기본값은 `STRICT`, 예외는 selector 또는 port 단위로 작게 둠.
- 메시 내부 서비스는 Auto mTLS를 우선 사용함. 모든 서비스에 `ISTIO_MUTUAL` DestinationRule을 기계적으로 생성하지 않음.
- 외부 HTTPS는 `ISTIO_MUTUAL`이 아님. `SIMPLE` 또는 `MUTUAL`로 분리함.
- `portLevelMtls` 포트는 Kubernetes Service port가 아니라 workload port 기준임.
- Envoy CPU가 높으면 mTLS만 의심하지 말고 connection 재사용, telemetry, access log, cluster/listener 수를 함께 확인함.
- 대규모 네임스페이스에서는 `Sidecar` 리소스와 `exportTo`로 xDS 설정 범위를 줄이는 것이 mTLS 성능 안정화에 직접적으로 도움됨.
- 관련 문서:
  - [Istio mTLS 가이드](./mtls-guide.md)
  - [mTLS 마이그레이션 가이드](./mtls-migration-guide.md)
  - [mTLS 디버그 가이드](./mtls-debug-guide.md)
  - [mTLS 인증서 라이프사이클](./mtls-certificate-lifecycle.md)
  - [공식 문서 - PeerAuthentication](https://istio.io/latest/docs/reference/config/security/peer_authentication/)
  - [공식 문서 - TLS Configuration / Auto mTLS](https://istio.io/latest/docs/ops/configuration/traffic-management/tls-configuration/)
  - [공식 문서 - Performance and Scalability](https://istio.io/latest/docs/ops/deployment/performance-and-scalability/)
  - [공식 문서 - Configuration Scoping](https://istio.io/latest/docs/ops/configuration/mesh/configuration-scoping/)
