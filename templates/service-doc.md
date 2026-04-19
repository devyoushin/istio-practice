# {서비스명} Istio 구성 문서

> **네임스페이스**: {namespace}
> **작성일**: {YYYY-MM-DD}
> **Istio 버전**: 1.28.3

---

## 1. 서비스 개요

| 항목 | 내용 |
|------|------|
| 서비스명 | {service-name} |
| 포트 | {PORT} |
| 프로토콜 | HTTP / gRPC / TCP |
| 버전 | v1, v2 |
| 네임스페이스 | {namespace} |

---

## 2. 트래픽 라우팅 구성

### VirtualService

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: {service-name}-vs
  namespace: {namespace}
spec:
  hosts:
    - {service-name}
  http:
    - route:
        - destination:
            host: {service-name}
            subset: v1
          weight: 100
```

### DestinationRule

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: {service-name}-dr
  namespace: {namespace}
spec:
  host: {service-name}
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
  subsets:
    - name: v1
      labels:
        version: v1
```

---

## 3. 보안 정책

### PeerAuthentication (mTLS)

```yaml
# 현재 모드: STRICT / PERMISSIVE
```

### AuthorizationPolicy

```yaml
# 허용된 소스 서비스 목록
```

---

## 4. 외부 연동 (ServiceEntry)

| 외부 서비스 | 호스트 | 포트 | 프로토콜 |
|------------|--------|------|---------|
| {서비스명} | {host} | {port} | HTTPS |

---

## 5. 모니터링

```bash
# 서비스 상태 확인
istioctl analyze -n {namespace}
kubectl get vs,dr,se,ap -n {namespace}
```

- Kiali: `{서비스명}` 그래프에서 에러율 확인
- Prometheus: `istio_requests_total{destination_service="{service-name}.{namespace}.svc.cluster.local"}`
