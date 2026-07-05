# Istio TLS/mTLS 핸드셰이크 동작 원리

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

TCP 3-way handshake가 **연결을 만드는 절차**라면, TLS handshake는 **암호화 통신을 시작하기 위한 신뢰와 키를 합의하는 절차**입니다. Istio mTLS는 TLS handshake에 클라이언트 인증서 검증까지 포함해 서비스와 서비스가 서로를 인증합니다.

```text
TCP 3-way handshake
Client ── SYN ───────────────▶ Server
Client ◀─ SYN/ACK ─────────── Server
Client ── ACK ───────────────▶ Server

TLS handshake
Client ── ClientHello ───────▶ Server
Client ◀─ ServerHello/Cert ── Server
Client ── Key/Verify ────────▶ Server
Client ◀─ Finished ────────── Server

Istio mTLS handshake
Client Envoy ── ClientHello ─────────────▶ Server Envoy
Client Envoy ◀─ ServerHello + Server Cert Server Envoy
Client Envoy ── Client Cert + Verify ───▶ Server Envoy
Client Envoy ◀─ Finished ──────────────── Server Envoy
```

애플리케이션 컨테이너는 보통 평문 HTTP/gRPC를 사용하고, 실제 TLS/mTLS는 양쪽 Envoy sidecar 사이에서 처리됩니다.

## 2. 전체 통신 흐름

예를 들어 `frontend`가 `backend`를 호출하면 실제 흐름은 다음과 같습니다.

```text
frontend app
  │ 1. HTTP 요청
  ▼
frontend Envoy sidecar
  │ 2. TCP 연결 생성
  │ 3. Istio mTLS handshake
  ▼
backend Envoy sidecar
  │ 4. 인증서 검증 성공 후 요청 복호화
  ▼
backend app
```

중요한 점은 애플리케이션이 직접 인증서를 읽거나 TLS 설정을 하지 않는다는 것입니다. 인증서 발급, 보관, 검증, 갱신은 `istiod`와 Envoy가 처리합니다.

## 3. TCP와 TLS의 역할 구분

| 계층 | 목적 | 대표 절차 | Istio에서 담당하는 위치 |
|------|------|-----------|-------------------------|
| TCP | 양 끝점 간 연결 생성 | SYN, SYN/ACK, ACK | Pod 네트워크, Envoy 간 socket |
| TLS | 암호화 채널 생성 | ClientHello, ServerHello, Certificate, Finished | Envoy sidecar |
| mTLS | 양방향 인증 | 서버 인증서 검증 + 클라이언트 인증서 검증 | Envoy sidecar |
| HTTP/gRPC | 실제 애플리케이션 요청 | GET, POST, gRPC method | App container |

TCP 연결이 성공해도 TLS 인증서 검증이 실패하면 애플리케이션 요청은 전달되지 않습니다. 따라서 `curl` 기준으로는 503, connection reset, upstream connect error처럼 보일 수 있습니다.

## 4. 일반 TLS와 Istio mTLS 차이

일반적인 HTTPS에서는 클라이언트가 서버 인증서만 검증하는 경우가 많습니다.

```text
Client
  │ 서버 인증서 검증
  ▼
Server
```

Istio mTLS에서는 서버와 클라이언트가 서로의 인증서를 검증합니다.

```text
Client Envoy
  │ 서버 인증서 검증
  │ 클라이언트 인증서 제시
  ▼
Server Envoy
  │ 클라이언트 인증서 검증
  │ 서버 인증서 제시
```

이때 각 워크로드 인증서에는 Kubernetes ServiceAccount 기반 SPIFFE ID가 들어갑니다.

```text
spiffe://cluster.local/ns/default/sa/frontend
spiffe://cluster.local/ns/default/sa/backend
```

서버 Envoy는 클라이언트 인증서의 SPIFFE ID를 확인하고, 이후 AuthorizationPolicy가 있다면 해당 identity를 기준으로 접근 허용 여부를 판단합니다.

## 5. Istio mTLS 핸드셰이크 단계

### 1. 인증서 준비

Pod가 시작되면 Envoy sidecar가 `istiod`에 CSR을 보내고 워크로드 인증서를 받습니다.

```text
Envoy sidecar
  │ CSR + ServiceAccount token
  ▼
istiod CA
  │ ServiceAccount token 검증
  │ SPIFFE ID 포함 인증서 발급
  ▼
Envoy sidecar
```

이 단계가 실패하면 mTLS handshake 이전에 이미 인증서가 없거나 유효하지 않은 상태가 됩니다.

### 2. TCP 연결

클라이언트 Envoy가 서버 Envoy로 TCP 연결을 생성합니다.

```text
Client Envoy ── SYN ─────▶ Server Envoy
Client Envoy ◀─ SYN/ACK ─ Server Envoy
Client Envoy ── ACK ─────▶ Server Envoy
```

여기까지는 암호화가 시작되지 않았습니다. 단순히 양쪽 Envoy 사이의 socket이 열린 상태입니다.

### 3. ClientHello

클라이언트 Envoy가 사용할 TLS 버전, cipher suite, SNI, ALPN 정보를 보냅니다.

```text
Client Envoy ── ClientHello ──▶ Server Envoy
```

Istio에서는 SNI와 ALPN이 중요합니다. Envoy는 이 정보를 이용해 어떤 filter chain과 클러스터 설정을 적용할지 결정합니다.

### 4. ServerHello와 서버 인증서 전달

서버 Envoy는 선택된 TLS 설정과 서버 인증서를 전달합니다.

```text
Client Envoy ◀─ ServerHello + Certificate ── Server Envoy
```

클라이언트 Envoy는 서버 인증서를 다음 기준으로 검증합니다.

- 루트 CA가 신뢰 가능한가
- 인증서가 만료되지 않았는가
- SAN의 SPIFFE ID가 기대한 trust domain과 일치하는가
- DestinationRule의 TLS 설정과 충돌하지 않는가

### 5. 클라이언트 인증서 전달

mTLS에서는 서버도 클라이언트 인증서를 요구합니다.

```text
Client Envoy ── Certificate + CertificateVerify ──▶ Server Envoy
```

서버 Envoy는 클라이언트 인증서를 검증하고, 클라이언트의 identity를 추출합니다.

```text
source.principal = spiffe://cluster.local/ns/default/sa/frontend
```

이 identity는 AuthorizationPolicy의 `principals` 조건과 연결됩니다.

### 6. 세션 키 합의와 Finished

양쪽 Envoy는 handshake 중 교환한 키 교환 정보를 바탕으로 대칭키를 만들고 `Finished` 메시지로 handshake 무결성을 확인합니다.

```text
Client Envoy ── Finished ──▶ Server Envoy
Client Envoy ◀─ Finished ── Server Envoy
```

이후부터 애플리케이션 요청은 대칭키로 암호화되어 전달됩니다.

### 7. HTTP/gRPC 요청 전달

서버 Envoy는 요청을 복호화하고 정책을 적용한 뒤 backend app으로 전달합니다.

```text
Client App
  │ HTTP/gRPC
  ▼
Client Envoy
  │ encrypted mTLS
  ▼
Server Envoy
  │ plain HTTP/gRPC over localhost or pod network
  ▼
Server App
```

## 6. TLS Termination 후 내부 mTLS 재암호화

외부 사용자가 HTTPS로 Istio Ingress Gateway에 접근하는 경우, TLS는 Gateway에서 한 번 종료됩니다. 이때 Gateway는 외부 클라이언트와 맺은 TLS 세션을 복호화한 뒤, 내부 서비스로 보낼 때 새 mTLS 세션을 생성합니다.

```text
외부 구간
Client ── HTTPS/TLS ──▶ Istio Ingress Gateway
                         │
                         │ TLS termination
                         │ - 외부 인증서로 HTTPS 종료
                         │ - HTTP 요청으로 라우팅 규칙 평가
                         ▼
내부 메시 구간
Istio Ingress Gateway ── Istio mTLS ──▶ Service Envoy sidecar ── HTTP ──▶ App
```

즉, `https://example.com` 요청이 Gateway에 들어오면 내부로 평문이 그대로 흘러가는 것이 아니라, Gateway Envoy가 내부 서비스의 Envoy와 다시 mTLS 핸드셰이크를 수행합니다. 단, 이 내부 mTLS는 목적지 워크로드에 사이드카가 있고 mTLS 정책이 활성화되어 있어야 적용됩니다.

### 1. 구간별 암호화 상태

| 구간 | 프로토콜 | 암호화 주체 | 설명 |
|------|----------|-------------|------|
| Client → Ingress Gateway | HTTPS/TLS | 외부 클라이언트와 Gateway Envoy | 외부 인증서로 TLS termination |
| Ingress Gateway 내부 처리 | HTTP | Gateway Envoy 내부 메모리 | VirtualService 라우팅, header/path 평가 |
| Ingress Gateway → Service Envoy | mTLS | Gateway Envoy와 Service Envoy | Istio 워크로드 인증서로 재암호화 |
| Service Envoy → App | HTTP/gRPC | 로컬 Pod 내부 통신 | 애플리케이션은 일반 HTTP/gRPC 수신 |

Gateway에서 TLS를 종료한다는 말은 “클러스터 내부가 모두 평문”이라는 뜻이 아닙니다. 외부 TLS 세션은 Gateway에서 끝나고, 내부 구간은 Istio mTLS 세션으로 다시 보호됩니다.

### 2. Gateway TLS termination 예시

외부 HTTPS를 받는 Gateway는 다음처럼 `tls.mode: SIMPLE`을 사용합니다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: my-app-gateway
  namespace: istio-ingress
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: my-app-tls
      hosts:
        - example.com
```

이 설정은 외부 클라이언트와 Gateway 사이의 HTTPS를 처리합니다. 내부 서비스로 mTLS를 적용하는 설정은 별도로 `PeerAuthentication`과 `DestinationRule` 또는 Istio auto mTLS에 의해 결정됩니다.

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

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app
  namespace: default
spec:
  host: my-app.default.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

### 3. 요청 처리 순서

```text
1. Client가 example.com:443으로 TCP 연결 생성
2. Client와 Ingress Gateway가 TLS handshake 수행
3. Gateway가 외부 TLS를 종료하고 HTTP 요청을 복호화
4. Gateway가 VirtualService 기준으로 목적지 Service 선택
5. Gateway Envoy가 my-app Envoy로 TCP 연결 생성
6. Gateway Envoy와 my-app Envoy가 Istio mTLS handshake 수행
7. Gateway Envoy가 HTTP 요청을 mTLS로 암호화해 전달
8. my-app Envoy가 요청을 복호화한 뒤 app container로 전달
```

이 구조에서는 외부 TLS 인증서와 내부 mTLS 인증서의 목적이 다릅니다.

| 인증서 | 사용 위치 | 목적 |
|--------|-----------|------|
| 외부 서버 인증서 | Client → Ingress Gateway | 브라우저/외부 클라이언트가 `example.com` 신뢰 |
| Istio 워크로드 인증서 | Ingress Gateway → Service Envoy | 서비스 간 identity 검증과 암호화 |

### 4. 확인 명령

Gateway가 내부 서비스로 mTLS를 사용하는지 확인합니다.

```bash
# Gateway Pod 확인
kubectl get pod -n istio-ingress -l istio=ingressgateway

# Gateway → 서비스 방향 TLS 상태 확인
istioctl authn tls-check <INGRESS_GATEWAY_POD>.istio-ingress my-app.default.svc.cluster.local

# Gateway Envoy의 upstream cluster TLS 설정 확인
istioctl proxy-config clusters <INGRESS_GATEWAY_POD> -n istio-ingress | grep my-app

# Gateway Envoy 인증서 확인
istioctl proxy-config secret <INGRESS_GATEWAY_POD> -n istio-ingress

# 서비스 Envoy에서 mTLS 핸드셰이크 통계 확인
kubectl exec <SERVICE_POD> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "ssl\\.(handshake|connection_error|session_reused)"
```

### 5. 자주 헷갈리는 지점

| 오해 | 실제 동작 |
|------|-----------|
| Gateway에서 TLS termination하면 내부는 무조건 평문이다 | Gateway 이후 내부 구간은 Istio mTLS로 다시 암호화 가능 |
| 외부 TLS 인증서가 내부 mTLS에도 사용된다 | 내부 mTLS는 istiod가 발급한 워크로드 인증서를 사용 |
| Gateway는 단순 L7 프록시라 mTLS 클라이언트가 아니다 | Gateway Envoy도 mesh 워크로드로서 내부 서비스에 mTLS 클라이언트가 될 수 있음 |
| PeerAuthentication만 STRICT면 항상 내부 mTLS가 된다 | 클라이언트 측 TLS 모드와 사이드카 주입 상태도 함께 맞아야 함 |

## 7. PeerAuthentication과 DestinationRule의 역할

Istio에서 mTLS는 수신 정책과 발신 정책이 함께 맞아야 합니다.

| 리소스 | 관점 | 의미 |
|--------|------|------|
| `PeerAuthentication` | 서버 수신 | 이 워크로드가 mTLS를 요구하는가 |
| `DestinationRule` | 클라이언트 발신 | 이 목적지로 보낼 때 TLS 모드를 어떻게 할 것인가 |

예시:

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

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: backend
  namespace: default
spec:
  host: backend.default.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

서버가 `STRICT`인데 클라이언트가 `DISABLE` 또는 평문으로 보내면 handshake가 성립하지 않습니다.

## 8. 실패 지점별 증상

| 실패 위치 | 대표 증상 | 확인 명령 |
|-----------|-----------|-----------|
| TCP 연결 실패 | `connection refused`, `UF` | `istioctl proxy-config clusters`, NetworkPolicy 확인 |
| ClientHello/SNI 불일치 | `filter_chain_not_found`, `NR` | `istioctl proxy-config listeners` |
| 서버 인증서 검증 실패 | `certificate verify failed`, `UF` | `istioctl proxy-config secret` |
| 클라이언트 인증서 없음 | `tls: client didn't provide a certificate` | 사이드카 주입 여부 확인 |
| PeerAuthentication/DestinationRule 충돌 | `CONFLICT`, 503 | `istioctl authn tls-check` |
| mTLS 성공 후 권한 거부 | 403, `rbac_access_denied` | `kubectl get authorizationpolicy` |

## 9. 모니터링 및 확인

### TLS 정책 확인

```bash
istioctl authn tls-check <CLIENT_POD>.default backend.default.svc.cluster.local
```

### 인증서 상태 확인

```bash
istioctl proxy-config secret <POD_NAME> -n default
```

### Envoy SSL 통계 확인

```bash
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "ssl\\.(handshake|connection_error|fail|session_reused)"
```

### 라우팅과 클러스터 TLS 설정 확인

```bash
istioctl proxy-config routes <POD_NAME> -n default
istioctl proxy-config clusters <POD_NAME> -n default
istioctl proxy-config listeners <POD_NAME> -n default
```

### Access Log에서 TLS/RBAC 실패 구분

```bash
kubectl logs <SERVER_POD> -n default -c istio-proxy | \
  grep -E " 503 | 403 |UF|UC|NR|rbac"
```

## 10. 트러블슈팅

### 증상: STRICT 적용 후 사이드카 없는 Pod만 실패

원인은 클라이언트가 mTLS 인증서를 제시할 Envoy를 갖고 있지 않기 때문입니다.

```bash
kubectl get pod <CLIENT_POD> -n default -o jsonpath='{.spec.containers[*].name}'
kubectl label namespace default istio-injection=enabled
kubectl rollout restart deployment/<CLIENT_DEPLOYMENT> -n default
```

### 증상: 인증서가 있는데도 handshake 실패

루트 CA 불일치, trust domain 불일치, 인증서 만료를 확인합니다.

```bash
istioctl proxy-config secret <CLIENT_POD> -n default
istioctl proxy-config secret <SERVER_POD> -n default
kubectl logs -n istio-system deployment/istiod | grep -Ei "cert|csr|error" | tail -30
```

### 증상: mTLS는 정상인데 403 발생

TLS handshake 이후 AuthorizationPolicy에서 차단된 상황입니다.

```bash
kubectl get authorizationpolicy -n default -o yaml
kubectl logs <SERVER_POD> -n default -c istio-proxy | grep -i rbac
```

## 11. 참고

- [mTLS 가이드](./mtls-guide.md)
- [mTLS 인증서 라이프사이클 가이드](./mtls-certificate-lifecycle.md)
- [mTLS 핸드셰이크 실패 디버깅 가이드](./mtls-debug-guide.md)
- [AuthorizationPolicy 가이드](./authorization-policy-guide.md)
