# Envoy 사이드카 트러블슈팅 가이드

> **작성일**: 2026-05-09
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio 운영 중 발생하는 트래픽 문제의 대부분은 Envoy 사이드카 설정에서 비롯됨. 이 문서는 실제 운영 장애 시나리오별로 Envoy 레벨의 원인 분석과 해결 방법을 정리함.

### 진단 흐름 원칙

```
증상 확인 (kubectl logs, curl)
       │
       ▼
Access Log 응답 플래그 확인 (UH / UF / UO / NR ...)
       │
       ▼
istioctl proxy-status → 동기화 상태 확인
       │
       ▼
istioctl proxy-config → Listener / Route / Cluster / Endpoint 확인
       │
       ▼
Admin API /config_dump → 실제 Envoy 설정 raw 확인
       │
       ▼
로그 레벨 debug 변경 → 상세 로그 추적
```

---

## 2. 시나리오별 트러블슈팅

### 시나리오 1: 503 UH — Endpoint 없음

**증상**: 요청이 503으로 실패하고 Access Log에 `UH` 플래그 표시

**원인**: Envoy의 Cluster에 HEALTHY Endpoint가 없음

```bash
# 1. Access Log에서 UH 확인
kubectl logs <CLIENT_POD> -n default -c istio-proxy | grep "UH"

# 2. 해당 서비스 Endpoint 상태 확인
istioctl proxy-config endpoint <CLIENT_POD> -n default | grep my-app
# ENDPOINT가 없거나 모두 UNHEALTHY 상태인지 확인

# 3. 서버 Pod 상태 및 레이블 확인
kubectl get pods -n default -l app=my-app --show-labels
# DestinationRule subset 레이블과 일치하는지 확인

# 4. DestinationRule subset 레이블 확인
kubectl get destinationrule my-app-dr -n default -o yaml | grep -A 5 subsets

# 5. Endpoints 리소스 확인 (쿠버네티스 레벨)
kubectl get endpoints my-app -n default
```

**해결:**
- Pod 레이블과 DestinationRule subset 레이블 불일치 → 레이블 수정
- Pod가 아예 없음 → Deployment 상태 확인 (`kubectl get deploy`)
- Readiness Probe 실패 → Pod 로그 확인

---

### 시나리오 2: 503 UF — 업스트림 연결 실패

**증상**: 요청이 503으로 실패하고 Access Log에 `UF` 플래그 표시

**원인**: Envoy가 업스트림 Pod에 연결을 시도했지만 실패 (TCP 레벨 에러)

```bash
# 1. 클라이언트 사이드카 로그 확인
kubectl logs <CLIENT_POD> -n default -c istio-proxy | grep "UF"

# 2. mTLS 설정 불일치 확인 (가장 흔한 원인)
istioctl authn tls-check <CLIENT_POD>.default my-app.default.svc.cluster.local

# 예시 출력
# HOST:PORT                                    STATUS  SERVER       CLIENT      AUTHN POLICY
# my-app.default.svc.cluster.local:8080        OK      STRICT       ISTIO_MUTUAL my-app-pa

# STATUS가 CONFLICT이면 mTLS 설정 불일치

# 3. 서버 Pod의 사이드카 로그 확인 (연결 시도가 오는지)
kubectl logs <SERVER_POD> -n default -c istio-proxy | tail -20

# 4. 서버 포트가 실제로 열려 있는지 확인
kubectl exec <CLIENT_POD> -n default -c istio-proxy -- \
  curl -v http://my-app:8080/health

# 5. iptables 규칙 확인 (사이드카 주입 여부)
kubectl exec <SERVER_POD> -n default -c istio-proxy -- \
  iptables -t nat -L -n | grep ISTIO
```

**해결:**
- mTLS 불일치 → PeerAuthentication 또는 DestinationRule TLS 모드 통일
- 서버가 사이드카 없이 배포됨 → `istio-injection: enabled` 레이블 확인 후 Pod 재시작

---

### 시나리오 3: 503 UO — Connection Pool 초과 (Circuit Breaker)

**증상**: 부하 상황에서 503이 발생하고 Access Log에 `UO` 플래그 표시

**원인**: DestinationRule의 `connectionPool` 한도를 초과해 Circuit Breaker가 동작

```bash
# 1. Connection Pool 초과 통계 확인
kubectl exec <CLIENT_POD> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "overflow"

# 예시: outbound|8080|v1|my-app...::upstream_cx_overflow: 15

# 2. 현재 활성 연결 수 확인
kubectl exec <CLIENT_POD> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "my-app" | grep "cx_active"

# 3. DestinationRule connectionPool 설정 확인
kubectl get destinationrule my-app-dr -n default -o yaml | grep -A 15 connectionPool
```

**Connection Pool 한도 조정:**

```yaml
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
        maxConnections: 100        # TCP 최대 연결 수 (기본: 1024)
      http:
        http2MaxRequests: 1000     # HTTP/2 최대 동시 요청 수 (기본: 1024)
        maxRequestsPerConnection: 10  # 연결당 최대 요청 수
        h2UpgradePolicy: DEFAULT
```

---

### 시나리오 4: 503 NR — 라우팅 규칙 없음

**증상**: Access Log에 `NR` 플래그 표시

**원인**: Envoy가 요청에 매칭되는 Route를 찾지 못함

```bash
# 1. Route 설정 확인
istioctl proxy-config route <CLIENT_POD> -n default

# 2. 특정 호스트/포트 Route 상세 확인
istioctl proxy-config route <CLIENT_POD> -n default --name 8080 -o json | \
  jq '.[].virtualHosts[]'

# 3. VirtualService 설정 확인
kubectl get virtualservice -n default -o yaml | grep -A 20 "hosts:"

# 4. istioctl analyze로 구성 오류 확인
istioctl analyze -n default
```

**자주 발생하는 NR 원인:**

| 원인 | 확인 방법 |
|------|---------|
| VirtualService의 `hosts`가 실제 서비스명과 불일치 | `kubectl get svc`로 서비스명 확인 |
| VirtualService가 다른 네임스페이스에 배포됨 | `-n` 옵션으로 네임스페이스 지정 확인 |
| Gateway 없이 Gateway 연결 시도 | `spec.gateways` 필드 확인 |
| 포트가 Service에 등록되지 않음 | `kubectl get svc my-app -o yaml` |

---

### 시나리오 5: 지연 급증 (Latency Spike)

**증상**: 정상적으로 응답이 오지만 특정 구간에서 지연이 급증함

```bash
# 1. Access Log에서 duration과 upstream_service_time 비교
# duration이 크고 upstream_service_time이 작으면 → Envoy 내 처리 지연
# duration과 upstream_service_time이 모두 크면 → 업스트림 Pod 문제

kubectl logs <POD_NAME> -n default -c istio-proxy | \
  jq 'select(.duration_ms | tonumber > 1000) | {path, duration_ms, upstream_service_time_ms, upstream_host}'

# 2. 재시도가 지연을 증가시키는지 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_rq_retry"

# 3. Outlier Detection으로 일부 Endpoint 제거 여부 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "failed_outlier_check"

# 4. 특정 Endpoint로만 요청이 몰리는지 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "my-app" | grep "rq_total"
```

---

### 시나리오 6: 사이드카가 주입되지 않음

**증상**: Pod는 정상인데 Envoy 로그가 없고 mTLS/트래픽 제어가 동작하지 않음

```bash
# 1. 사이드카 주입 여부 확인
kubectl get pod <POD_NAME> -n default -o yaml | grep -A 5 "containers:"
# istio-proxy 컨테이너가 없으면 주입 안 됨

# 2. 네임스페이스 레이블 확인
kubectl get namespace default --show-labels | grep "istio-injection"
# istio-injection=enabled 이어야 함

# 3. Pod 레벨 주입 비활성화 어노테이션 확인
kubectl get pod <POD_NAME> -n default -o yaml | grep "sidecar.istio.io/inject"
# "false"로 설정됐다면 주입 비활성화 상태

# 4. MutatingWebhookConfiguration 상태 확인
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml | \
  grep "namespaceSelector" -A 10

# 5. 해결: Pod 재시작으로 주입 적용
kubectl rollout restart deployment/my-app -n default
```

---

## 3. 로그 레벨 기반 심층 디버깅

```bash
# 특정 컴포넌트 debug 활성화
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/logging?http=debug&router=debug"

# 실시간 로그 확인
kubectl logs <POD_NAME> -n default -c istio-proxy -f

# 조사 완료 후 반드시 warning으로 원복
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST "http://localhost:15000/logging?level=warning"
```

---

## 4. 모니터링 및 확인

```bash
# 전체 사이드카 동기화 상태 확인
istioctl proxy-status

# 특정 Pod의 전체 Envoy 구성 요약
istioctl proxy-config all <POD_NAME> -n default

# Istio 구성 분석 (VirtualService/DestinationRule 오류)
istioctl analyze -n default

# mTLS 연결 상태 확인
istioctl authn tls-check <POD_NAME>.default

# 특정 서비스 간 연결 상태 확인
istioctl authn tls-check <POD_NAME>.default my-app.default.svc.cluster.local
```

### 진단 명령어 치트시트

| 문제 유형 | 1차 진단 명령어 |
|----------|--------------|
| xDS 동기화 | `istioctl proxy-status` |
| 라우팅 규칙 | `istioctl proxy-config route <POD> -n default` |
| Endpoint 없음 | `istioctl proxy-config endpoint <POD> -n default` |
| mTLS 불일치 | `istioctl authn tls-check <POD>.default` |
| 구성 오류 | `istioctl analyze -n default` |
| 설정 raw 확인 | `curl localhost:15000/config_dump` |
| 에러 통계 | `curl localhost:15000/stats \| grep -E "overflow\|timeout\|retry"` |

---

## 5. TIP

- 문제가 클라이언트 사이드카인지 서버 사이드카인지 먼저 특정해야 함. 클라이언트 사이드카 로그에 에러 응답 플래그가 있으면 클라이언트 측 문제
- `istioctl proxy-config`는 istiod를 통해 정보를 가져오므로 실제 Envoy 상태와 미세하게 다를 수 있음. 정확한 확인은 Admin API `/config_dump` 사용
- EKS 환경에서 iptables 규칙 확인 시 `NET_ADMIN` 권한이 필요함. `istio-init` 컨테이너가 이 작업을 수행
- Envoy 재시작 없이 대부분의 설정은 xDS로 hot reload 가능하지만, 일부 리스너 레벨 변경은 재시작이 필요할 수 있음
