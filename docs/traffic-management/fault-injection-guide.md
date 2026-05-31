# Istio Fault Injection 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

**Fault Injection**은 VirtualService에서 의도적으로 지연(delay)이나 오류(abort)를 주입하여 장애 상황을 시뮬레이션하는 기능입니다.

> 실제 서비스를 다운시키지 않고 "만약 이 서비스가 500ms 느려지면?"을 테스트할 수 있습니다.

---

## 2. 두 가지 장애 유형

| 유형 | 설명 | 테스트 목적 |
|------|------|-------------|
| `delay` | 응답을 의도적으로 지연 | 타임아웃 설정 검증, 느린 의존성 대응 확인 |
| `abort` | HTTP 오류 코드 반환 | 에러 핸들링, Circuit Breaker 동작 검증 |

---

## 3. 설정 예시

### 1. 지연 주입 (Delay)

요청의 50%에 5초 지연을 주입합니다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app
  namespace: default
spec:
  hosts:
  - my-app
  http:
  - fault:
      delay:
        percentage:
          value: 50.0    # 50% 요청에만 적용
        fixedDelay: 5s   # 5초 지연
    route:
    - destination:
        host: my-app
        subset: v1
```

```bash
kubectl apply -f fault-delay.yaml

# 테스트: 응답 시간 측정
time curl http://my-app
```

### 2. 오류 주입 (Abort)

요청의 30%에 HTTP 500 오류를 반환합니다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app
  namespace: default
spec:
  hosts:
  - my-app
  http:
  - fault:
      abort:
        percentage:
          value: 30.0       # 30% 요청에만 적용
        httpStatus: 500     # 반환할 HTTP 상태 코드
    route:
    - destination:
        host: my-app
        subset: v1
```

```bash
# 10번 호출해서 약 3번 500 오류 발생 확인
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" http://my-app; done
```

### 3. 지연 + 오류 동시 주입

```yaml
http:
- fault:
    delay:
      percentage:
        value: 50.0
      fixedDelay: 3s
    abort:
      percentage:
        value: 20.0
      httpStatus: 503
  route:
  - destination:
      host: my-app
      subset: v1
```

---

## 4. 실전 시나리오: Retry 설정 검증

Fault Injection은 Retry 설정이 실제로 동작하는지 확인하는 데 유용합니다.

**1. 오류 주입 + Retry 설정**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app
  namespace: default
spec:
  hosts:
  - my-app
  http:
  - fault:
      abort:
        percentage:
          value: 50.0
        httpStatus: 503
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx
    route:
    - destination:
        host: my-app
        subset: v1
```

**2. 검증**

```bash
# 성공률 확인 (Retry 덕분에 실제 실패율은 50%보다 낮아야 함)
for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\n" http://my-app; done

# Jaeger에서 retry 흔적 확인
istioctl dashboard jaeger
```

---

## 5. 특정 사용자에게만 장애 주입 (헤더 기반)

```yaml
http:
- match:
  - headers:
      x-test-user:
        exact: "fault-tester"   # 이 헤더가 있는 요청에만 적용
  fault:
    delay:
      fixedDelay: 10s
      percentage:
        value: 100.0
  route:
  - destination:
      host: my-app
      subset: v1
# 그 외 요청은 정상
- route:
  - destination:
      host: my-app
      subset: v1
```

```bash
# 일반 사용자: 정상
curl http://my-app

# 테스트 사용자: 10초 지연
curl -H "x-test-user: fault-tester" http://my-app
```

---

## 6. 장애 주입 제거

테스트 후 반드시 제거해야 합니다.

```bash
# fault 블록을 제거한 VirtualService 재적용
kubectl apply -f virtual-service-90-10.yaml

# 또는 직접 편집
kubectl edit virtualservice my-app
```

---

## 7. 모니터링 및 확인

```bash
# VirtualService 적용 상태 확인
kubectl get virtualservice my-app -n default -o yaml

# Envoy가 수신한 라우팅 설정 확인
istioctl proxy-config routes deploy/my-app -n default

# 지연과 오류 발생 비율 확인
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code} %{time_total}\n" http://my-app
done
```

---

## 8. 트러블슈팅

| 증상 | 확인 항목 |
|------|-----------|
| 지연이나 오류가 발생하지 않음 | `VirtualService`의 `hosts`, `gateways`, `match` 조건 확인 |
| 모든 요청이 실패함 | `abort.percentage` 값과 라우팅 대상 subset 존재 여부 확인 |
| 재시도가 발생하지 않음 | `retryOn`, `attempts`, `perTryTimeout` 설정과 클라이언트 타임아웃 확인 |

---

## 9. 참고

- [공식문서 - Fault Injection](https://istio.io/latest/docs/tasks/traffic-management/fault-injection/)
