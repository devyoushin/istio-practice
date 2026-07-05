# Istio ServiceEntry 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

**ServiceEntry**는 Istio 서비스 메시 외부에 있는 서비스(외부 API, DB, 레거시 서비스 등)를 메시의 레지스트리에 등록하는 리소스입니다.

> 기본적으로 Istio는 메시 내부 서비스만 인식합니다. 외부 호출도 Istio가 제어하려면 ServiceEntry로 등록해야 합니다.

---

## 2. 기본 동작 이해

```text
기본 설정 (outboundTrafficPolicy: ALLOW_ANY)
Pod → 외부 API → 응답 (Istio 제어 없음, 모니터링 불가)

ServiceEntry 등록 후
Pod → Envoy → ServiceEntry → 외부 API → 응답
              (라우팅, 재시도, 타임아웃, 모니터링 가능)
```

---

## 3. outboundTrafficPolicy 설정

외부 트래픽 기본 정책을 먼저 확인합니다.

```bash
kubectl get istiooperator -n istio-system -o yaml | grep outboundTrafficPolicy
```

| 모드 | 설명 |
|------|------|
| `ALLOW_ANY` | 등록되지 않은 외부 서비스도 허용 (기본값) |
| `REGISTRY_ONLY` | ServiceEntry에 등록된 서비스만 허용, 나머지 차단 |

```yaml
# REGISTRY_ONLY로 변경 (보안 강화)
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
```

---

## 4. 설정 예시

### 1. 외부 HTTPS API 등록

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-api
  namespace: default
spec:
  hosts:
  - api.example.com           # 접근할 외부 도메인
  ports:
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS             # DNS로 IP 해석
  location: MESH_EXTERNAL     # 메시 외부임을 명시
```

```bash
kubectl apply -f service-entry-external-api.yaml

# 테스트
kubectl exec -it <pod-name> -- curl https://api.example.com
```

### 2. 외부 HTTP API + 타임아웃/재시도 적용

ServiceEntry로 등록한 후 VirtualService로 트래픽 정책을 적용할 수 있습니다.

```yaml
# ServiceEntry
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-api
  namespace: default
spec:
  hosts:
  - api.example.com
  ports:
  - number: 80
    name: http
    protocol: HTTP
  resolution: DNS
  location: MESH_EXTERNAL
---
# VirtualService로 정책 추가
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: external-api
  namespace: default
spec:
  hosts:
  - api.example.com
  http:
  - timeout: 3s
    retries:
      attempts: 3
      perTryTimeout: 1s
    route:
    - destination:
        host: api.example.com
        port:
          number: 80
```

### 3. 고정 IP 외부 서비스 등록

DNS가 아닌 고정 IP로 접근하는 외부 서비스(예: 사내 레거시 서버)입니다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: legacy-db
  namespace: default
spec:
  hosts:
  - legacy-db.internal
  addresses:
  - 192.168.1.100/32          # 고정 IP
  ports:
  - number: 5432
    name: postgres
    protocol: TCP
  resolution: STATIC
  location: MESH_EXTERNAL
  endpoints:
  - address: 192.168.1.100
```

### 4. 메시 내부 서비스를 외부에서도 접근 가능하게 (MESH_INTERNAL)

다른 클러스터의 서비스나 VM 워크로드를 메시에 통합할 때 사용합니다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: other-cluster-service
  namespace: default
spec:
  hosts:
  - other-service.other-namespace.svc.cluster.local
  ports:
  - number: 80
    name: http
    protocol: HTTP
  location: MESH_INTERNAL     # 메시 내부로 취급 (mTLS 적용)
  resolution: DNS
```

---

## 5. REGISTRY_ONLY 환경에서 작업

보안을 위해 `REGISTRY_ONLY`를 사용하는 경우, 모든 외부 서비스를 ServiceEntry로 등록해야 합니다.

```bash
# 등록되지 않은 외부 서비스 호출 시
kubectl exec -it <pod-name> -- curl https://unregistered-api.com
# 예상: 502 Bad Gateway (Istio가 차단)

# ServiceEntry 등록 후 재시도
kubectl apply -f service-entry.yaml
kubectl exec -it <pod-name> -- curl https://unregistered-api.com
# 예상: 정상 응답
```

---

## 6. 모니터링 및 확인

```bash
kubectl get serviceentry
kubectl describe serviceentry external-api

# Kiali에서 외부 서비스 트래픽 확인
istioctl dashboard kiali
# Graph에서 외부 서비스가 노드로 표시됨
```

---

## 7. 트러블슈팅

| 증상 | 확인 항목 |
|------|-----------|
| 외부 호출이 502로 실패함 | `ServiceEntry`의 `hosts`, `ports`, `resolution` 확인 |
| DNS 해석이 실패함 | `resolution: DNS`와 클러스터 DNS 정책 확인 |
| `REGISTRY_ONLY`에서만 실패함 | 대상 외부 도메인이 ServiceEntry에 등록되었는지 확인 |
| Kiali에 외부 노드가 보이지 않음 | 애플리케이션 Pod에 사이드카가 주입되었는지 확인 |

---

## 8. 참고

- [공식문서 - ServiceEntry](https://istio.io/latest/docs/reference/config/networking/service-entry/)
- [공식문서 - Egress 트래픽 제어](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/)
