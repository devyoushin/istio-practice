# Istio Circuit Breaker 실습 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

Circuit Breaker(서킷 브레이커)는 특정 서비스가 비정상 상태일 때 해당 서비스로의 요청을 차단하여 장애가 전파되는 것을 막는 패턴입니다. Istio에서는 DestinationRule의 `outlierDetection`으로 구현합니다.

> `destinationrule-guide.md`에서 개념을 확인했다면, 이 문서에서 실제로 트리거하고 복구되는 과정을 실습합니다.

---

## 2. Circuit Breaker 상태

```text
       요청 실패 누적
CLOSED ──────────────→ OPEN (차단)
  ↑                        │
  │     일정 시간 후        │
  └── HALF-OPEN ←──────────┘
     (일부 요청 허용 → 성공하면 CLOSED 복귀)
```

| 상태 | 설명 |
|------|------|
| CLOSED | 정상. 모든 요청 통과 |
| OPEN | 차단. 모든 요청 즉시 실패 (503) |
| HALF-OPEN | 일부 요청만 허용하여 서비스 복구 여부 확인 |

---

## 3. 설정 (DestinationRule)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1          # 최대 TCP 연결 수
      http:
        http1MaxPendingRequests: 1 # 대기 중인 최대 요청 수
        maxRequestsPerConnection: 1
    outlierDetection:
      consecutive5xxErrors: 3      # 연속 3번 5xx 오류 시 제외
      interval: 10s                # 분석 주기
      baseEjectionTime: 30s        # 최초 제외 시간 (이후 배수로 증가)
      maxEjectionPercent: 100      # 최대 제외 가능한 인스턴스 비율
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

---

## 4. 실습: Circuit Breaker 트리거

### 1. 준비: fortio로 부하 테스트

```bash
# fortio 설치 (부하 테스트 도구)
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.21/samples/httpbin/sample-client/fortio-deploy.yaml

FORTIO_POD=$(kubectl get pods -l app=fortio -o jsonpath='{.items[0].metadata.name}')
```

### 2. 정상 상태 확인

```bash
# 단일 요청 테스트
kubectl exec "$FORTIO_POD" -- fortio load -c 1 -qps 0 -n 20 http://my-app
# 예상: 200 응답 100%
```

### 3. 동시 연결 수 초과로 Circuit Breaker 트리거

```bash
# 동시 연결 2개 (maxConnections: 1 초과)
kubectl exec "$FORTIO_POD" -- fortio load -c 2 -qps 0 -n 20 http://my-app
# 예상: 일부 요청 503 (pending requests overflow)
```

### 4. 더 강하게 트리거

```bash
# 동시 연결 3개, 30번 요청
kubectl exec "$FORTIO_POD" -- fortio load -c 3 -qps 0 -n 30 http://my-app
# 예상: 503 비율 증가, Upstream overflow 로그
```

---

## 5. 실습: Outlier Detection

비정상 응답을 반환하는 Pod를 로드밸런서 대상에서 자동으로 제외합니다.

### 1. 오류를 반환하는 v2 배포

```bash
# v2 Pod에 오류 주입 (환경변수로 500 반환하도록 설정 - 앱에 따라 다름)
# 또는 Fault Injection 활용
kubectl apply -f fault-injection-guide.yaml  # abort 100% 설정
```

### 2. 트래픽 분산 상태에서 오류 확인

```bash
for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\n" http://my-app; done
# 초기: v2가 500을 반환하는 것이 보임
```

### 3. Outlier Detection 후 자동 제외 확인

```bash
# consecutive5xxErrors: 3 → 3번 연속 실패 후 30초간 제외
# 30초 후 재시도: v2가 다시 로드밸런서에 포함됨
```

---

## Circuit Breaker 상태 확인

```bash
# 특정 서비스의 Envoy 통계 확인
kubectl exec "$FORTIO_POD" -- pilot-agent request GET stats | grep pending

# Kiali 대시보드에서 실시간 확인
istioctl dashboard kiali
# Graph > 해당 서비스 선택 > Inbound/Outbound Metrics에서 503 비율 확인

# Envoy 관리 페이지 직접 확인
kubectl exec <pod-name> -c istio-proxy -- pilot-agent request GET clusters | grep -i ejected
```

---

## 설정값 가이드

| 필드 | 권장값 | 설명 |
|------|--------|------|
| `consecutive5xxErrors` | 5 | 너무 낮으면 일시적 오류에도 차단됨 |
| `interval` | 30s | 분석 주기 |
| `baseEjectionTime` | 30s | 처음 제외 시간 (2번째는 60s, 3번째는 90s) |
| `maxEjectionPercent` | 50 | 100으로 설정 시 모든 Pod가 제외될 수 있음 |

---

## 참고

- [공식문서 - Circuit Breaking](https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/)
- [공식문서 - Outlier Detection](https://istio.io/latest/docs/reference/config/networking/destination-rule/#OutlierDetection)
