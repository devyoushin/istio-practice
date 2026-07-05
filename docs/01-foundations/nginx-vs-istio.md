# Nginx 관점에서 이해하는 Istio

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

Nginx는 주로 **외부 요청을 받아서 백엔드로 전달하는 고성능 프록시**로 사용합니다. 반면 Istio는 Envoy 프록시를 모든 워크로드 옆에 붙여서 **서비스 간 통신 전체를 정책으로 제어하는 서비스 메시**입니다.

핵심 차이는 위치입니다.

```text
Nginx 중심 구조

Client
  │
  ▼
Nginx
  │
  ├── app-v1
  └── app-v2

Istio 중심 구조

Client
  │
  ▼
Istio Ingress Gateway(Envoy)
  │
  ▼
Service A + Envoy sidecar
  │
  ▼
Service B + Envoy sidecar
```

Nginx가 앞단에서 트래픽을 잘 처리하는 구조라면, Istio는 앞단뿐 아니라 서비스 내부 호출까지 Envoy가 관찰하고 제어하는 구조입니다.

## 2. 기능 매핑

| Nginx에서 하던 일 | Istio에서 담당하는 것 | 설명 |
|------------------|----------------------|------|
| `server` 블록 | `Gateway` | 외부에서 들어오는 host, port, TLS 진입점 정의 |
| `location` 블록 | `VirtualService.http.match` | URI, header, method 기반 라우팅 조건 정의 |
| `proxy_pass` | `VirtualService.route.destination` | 요청을 보낼 Kubernetes Service 또는 subset 지정 |
| `upstream` | `DestinationRule.subsets` | 버전별 Pod 그룹과 로드밸런싱 정책 정의 |
| `weight` 기반 분산 | `VirtualService.route.weight` | 카나리, 블루/그린, 점진 배포 |
| `proxy_next_upstream` | `VirtualService.retries` | 실패 시 재시도 정책 |
| `proxy_read_timeout` | `VirtualService.timeout` | 요청 단위 타임아웃 |
| `limit_req` | `EnvoyFilter` 또는 외부 Rate Limit 서비스 | 로컬/글로벌 Rate Limiting |
| `access_log` | Envoy access log, Prometheus metric, tracing | 요청 로그와 메트릭, 분산 추적 |
| TLS termination | `Gateway.tls` | 외부 TLS 종료 |
| 내부 TLS 구성 | `PeerAuthentication`, `DestinationRule.tls` | 서비스 간 mTLS 자동화 |
| IP allow/deny | `AuthorizationPolicy` | 서비스, namespace, path, method 기반 접근 제어 |

## 3. 트래픽 관리 관점

Nginx에서는 `upstream`과 `location`을 조합해 라우팅합니다.

```nginx
upstream my_app {
    server my-app-v1:8080 weight=90;
    server my-app-v2:8080 weight=10;
}

server {
    listen 80;

    location / {
        proxy_pass http://my_app;
    }
}
```

Istio에서는 이 역할이 `VirtualService`와 `DestinationRule`로 나뉩니다.

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
    - route:
        - destination:
            host: my-app
            subset: v1
          weight: 90
        - destination:
            host: my-app
            subset: v2
          weight: 10
```

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app
  namespace: default
spec:
  host: my-app
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

정리하면 Nginx의 `upstream + location + proxy_pass`를 Istio에서는 다음처럼 분리합니다.

```text
VirtualService  = 어디로 보낼지 결정
DestinationRule = 목적지 그룹과 연결 정책 결정
Gateway         = 외부 진입점 결정
```

## 4. 성능 관점

Nginx는 단일 프록시 계층에서 매우 낮은 오버헤드로 대량 요청을 처리하는 데 강합니다. Istio는 서비스마다 Envoy sidecar가 붙기 때문에 더 많은 기능을 얻는 대신 CPU, 메모리, 레이턴시 비용이 생깁니다.

| 항목 | Nginx | Istio |
|------|-------|-------|
| 프록시 위치 | 주로 edge 또는 reverse proxy | ingress gateway + 모든 Pod sidecar |
| 레이턴시 | 프록시 1회 경유 중심 | 서비스 호출마다 sidecar 경유 |
| 리소스 사용 | Nginx 프로세스 중심 | Pod마다 Envoy 리소스 필요 |
| 설정 적용 | Nginx reload 또는 동적 모듈 | istiod가 xDS로 Envoy에 동적 배포 |
| 관측 범위 | Nginx를 지나는 트래픽 중심 | 서비스 간 east-west 트래픽까지 관측 |

Istio 성능 튜닝의 핵심은 기능을 무조건 켜는 것이 아니라 필요한 범위에만 적용하는 것입니다.

- 사이드카 리소스 요청/제한 설정
- Envoy concurrency 조정
- 불필요한 Envoy metric 제거
- `Sidecar` 리소스로 egress listener 범위 축소
- tracing sampling 비율 조정
- mTLS, AuthorizationPolicy 적용 범위 단계적 확대

관련 문서: [Istio 성능 튜닝 가이드](../02-installation/istio-performance-tuning.md)

## 5. 보안 관점

Nginx에서 TLS를 설정하면 보통 외부 사용자가 Nginx까지 안전하게 접근하는 것을 보장합니다.

```text
Client --TLS--> Nginx --plain HTTP 또는 내부 TLS--> App
```

Istio는 외부 TLS와 내부 mTLS를 분리해서 관리합니다.

```text
Client --TLS--> Ingress Gateway --mTLS--> Service A --mTLS--> Service B
```

외부 HTTPS는 Ingress Gateway에서 termination되지만, Gateway 이후 내부 서비스 호출은 Istio 워크로드 인증서로 다시 mTLS 암호화될 수 있습니다. 즉, 외부 TLS와 내부 mTLS는 서로 다른 인증서와 신뢰 체계를 사용하는 별도 세션입니다.

Istio에서 가져가는 보안 이점은 다음과 같습니다.

- 서비스 간 통신 암호화 자동화
- ServiceAccount 기반 워크로드 identity 사용
- namespace, path, method, principal 기준 접근 제어
- PERMISSIVE에서 STRICT로 점진 전환 가능
- 인증서 발급과 회전을 istiod/SDS가 관리

관련 문서:

- [mTLS 가이드](../04-security/mtls-guide.md)
- [TLS/mTLS 핸드셰이크 동작 원리](../04-security/tls-mtls-handshake-flow.md)
- [AuthorizationPolicy 가이드](../04-security/authorization-policy-guide.md)

## 6. 관측 관점

Nginx의 운영 가시성은 access log, error log, stub status, exporter 중심입니다. Istio는 Envoy가 모든 요청 경로에 있으므로 다음 데이터를 기본적으로 얻기 쉽습니다.

| 관측 항목 | Nginx | Istio |
|-----------|-------|-------|
| Access log | Nginx access log | Envoy access log |
| 요청 수/지연/오류율 | exporter 또는 로그 기반 | `istio_requests_total`, duration bucket |
| 서비스 그래프 | 별도 구성 필요 | Kiali로 서비스 간 호출 관계 확인 |
| 분산 추적 | 애플리케이션/프록시 연동 필요 | Jaeger/Zipkin/OTel 연동 |
| 장애 위치 | Nginx 앞단 중심 | source/destination workload 기준 분석 |

Nginx가 “프록시를 지나간 요청”을 보는 데 강하다면, Istio는 “서비스 간 호출 관계와 정책 적용 결과”를 보는 데 강합니다.

관련 문서: [Observability 가이드](../05-observability/observability-guide.md)

## 7. 언제 Nginx를 쓰고 언제 Istio를 쓰는가?

| 상황 | 권장 접근 |
|------|-----------|
| 단순 reverse proxy, 정적 파일, 캐싱, gzip 중심 | Nginx가 단순하고 효율적 |
| Ingress 계층의 HTTP 라우팅만 필요 | Nginx Ingress 또는 Istio Ingress Gateway 모두 가능 |
| 서비스 간 mTLS, RBAC, 카나리, 재시도, 타임아웃을 일관 적용 | Istio 적합 |
| 서비스 간 호출 관계와 장애 지점을 표준 메트릭으로 보고 싶음 | Istio 적합 |
| 프록시 오버헤드를 최소화해야 하는 초고성능 edge | Nginx 우선 검토 |
| 플랫폼 차원에서 보안/트래픽 정책을 중앙 관리해야 함 | Istio 우선 검토 |

실무에서는 둘 중 하나만 고르는 구조가 아닐 수 있습니다.

```text
Client
  │
  ▼
Cloud Load Balancer
  │
  ├── Nginx Ingress
  │      └── 단순 웹/정적/캐싱 서비스
  │
  └── Istio Ingress Gateway
         └── 서비스 메시가 필요한 마이크로서비스
```

## 8. 트러블슈팅 관점

Nginx에서는 설정 파일과 로그를 먼저 봅니다.

```bash
nginx -t
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
```

Istio에서는 Kubernetes 리소스와 Envoy 설정 동기화 상태를 함께 봅니다.

```bash
istioctl analyze -A
istioctl proxy-status
istioctl proxy-config routes deploy/my-app -n default
istioctl proxy-config clusters deploy/my-app -n default
kubectl logs deploy/my-app -c istio-proxy -n default
```

Istio 문제는 보통 다음 중 하나입니다.

- VirtualService host 또는 Gateway 매칭 불일치
- DestinationRule subset label 불일치
- mTLS STRICT 적용 후 non-mesh 워크로드 호출 실패
- AuthorizationPolicy selector 또는 principal 불일치
- Envoy sidecar 미주입
- istiod와 Envoy의 xDS 동기화 실패

## 9. 참고

- [VirtualService 가이드](../03-traffic-management/virtualservice-guide.md)
- [DestinationRule 가이드](../03-traffic-management/destinationrule-guide.md)
- [Gateway/Egress Gateway 가이드](../03-traffic-management/egress-gateway-guide.md)
- [Envoy 아키텍처](../06-envoy-deep-dive/envoy-architecture.md)
