# Istio Egress Gateway 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

**Egress Gateway**는 메시 내부에서 외부로 나가는 트래픽을 하나의 게이트웨이로 모아서 제어하는 컴포넌트입니다.

> Ingress Gateway가 "외부 → 내부" 트래픽의 관문이라면, Egress Gateway는 "내부 → 외부" 트래픽의 관문입니다.

---

## 2. 왜 Egress Gateway가 필요한가?

```
Egress Gateway 없이 (ServiceEntry만 사용)
Pod A ─────────────────────────────→ 외부 API
Pod B ─────────────────────────────→ 외부 API
Pod C ─────────────────────────────→ 외부 API
(각 Pod가 직접 외부 호출 → 감사/제어 어려움)

Egress Gateway 사용
Pod A ─→ Egress Gateway ─→ 외부 API
Pod B ─→ Egress Gateway ─→ 외부 API   (단일 출구 → 감사, 정책 적용, 모니터링 통합)
Pod C ─→ Egress Gateway ─→ 외부 API
```

**주요 이점**
- **감사(Audit)**: 외부로 나가는 모든 트래픽이 단일 포인트를 통과 → 로그 수집 용이
- **보안**: 게이트웨이 Pod에만 외부 네트워크 접근 권한 부여 (NetworkPolicy)
- **정책 일관성**: 재시도, 타임아웃, mTLS 등을 한 곳에서 관리

---

## 3. 설치 확인

EKS 환경에서 Egress Gateway는 별도 설치가 필요합니다.

```bash
# 기존 istio-ingress 네임스페이스에 추가 설치
helm install istio-egress istio/gateway \
  -n istio-egress \
  --create-namespace \
  --set service.type=ClusterIP   # Egress는 외부 노출 불필요

kubectl get pods -n istio-egress
```

---

## 4. 설정 구조

Egress Gateway 설정은 3개의 리소스가 협력합니다.

```
Pod
 │
 ▼
[VirtualService] → "외부 트래픽을 Egress Gateway로 보내라"
 │
 ▼
[Gateway] → "istio-egressgateway에서 이 포트/호스트를 처리"
 │
 ▼
[VirtualService (두 번째)] → "Gateway에서 실제 외부 서비스로 보내라"
 │
 ▼
외부 API
```

---

## 5. 설정 예시: HTTP 외부 서비스

### 1. ServiceEntry (외부 서비스 등록)

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
  - number: 80
    name: http
    protocol: HTTP
  resolution: DNS
  location: MESH_EXTERNAL
```

### 2. Gateway (Egress Gateway 정의)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: egress-gateway
  namespace: istio-egress
spec:
  selector:
    istio: egressgateway       # Egress Gateway Pod 선택
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - api.example.com
```

### 3. VirtualService (트래픽 경로 설정)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: external-api-via-egress
  namespace: default
spec:
  hosts:
  - api.example.com
  gateways:
  - mesh                   # 메시 내부 Pod의 요청
  - egress-gateway         # Egress Gateway 통과 후 요청
  http:
  # 1. 메시 내부 → Egress Gateway로 전달
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-egress.svc.cluster.local
        port:
          number: 80
  # 2. Egress Gateway → 실제 외부 서비스로 전달
  - match:
    - gateways:
      - egress-gateway
      port: 80
    route:
    - destination:
        host: api.example.com
        port:
          number: 80
```

---

## 6. 설정 예시: HTTPS 외부 서비스

HTTPS 트래픽은 TLS Origination(TLS 종단)을 Egress Gateway에서 처리합니다.

```yaml
# ServiceEntry
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-https-api
  namespace: default
spec:
  hosts:
  - api.example.com
  ports:
  - number: 443
    name: tls
    protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
---
# DestinationRule: Egress Gateway → 외부 서비스 간 TLS 설정
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: external-api-tls
  namespace: default
spec:
  host: api.example.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE           # 단방향 TLS (일반 HTTPS)
```

---

## 7. 모니터링 및 확인

```bash
# Pod에서 외부 API 호출
kubectl exec -it <pod-name> -- curl http://api.example.com

# Egress Gateway 로그에서 트래픽 확인
kubectl logs -n istio-egress -l istio=egressgateway -f

# Kiali에서 확인: Graph에서 Egress Gateway 노드가 중간에 표시됨
istioctl dashboard kiali
```

---

## 8. NetworkPolicy와 함께 사용 (보안 강화)

Egress Gateway를 사용하는 진짜 이유는 NetworkPolicy와 결합할 때 완성됩니다.

```yaml
# 일반 Pod는 외부 직접 접근 금지
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-egress
  namespace: default
spec:
  podSelector: {}              # 모든 Pod에 적용
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: istio-egress  # Egress Gateway 네임스페이스만 허용
```

이렇게 하면 Egress Gateway를 우회한 직접 외부 호출이 NetworkPolicy 수준에서 차단됩니다.

---

## 9. 트러블슈팅

| 증상 | 확인 항목 |
|------|-----------|
| Egress Gateway Pod가 없음 | `istio-egress` 네임스페이스와 Helm 설치 상태 확인 |
| 외부 호출이 502로 실패함 | `ServiceEntry`, `Gateway`, `VirtualService`의 host/port 일치 여부 확인 |
| Gateway를 우회해 외부 호출됨 | NetworkPolicy 적용 여부와 `outboundTrafficPolicy` 설정 확인 |
| HTTPS 호출이 실패함 | TLS origination용 DestinationRule의 `tls.mode` 확인 |

---

## 10. 참고

- [공식문서 - Egress Gateway](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/)
- [공식문서 - Egress TLS Origination](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/)
