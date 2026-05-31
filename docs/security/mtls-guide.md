# Istio mTLS (Mutual TLS) 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

Istio는 서비스 간 통신을 자동으로 암호화하고 상호 인증합니다. 이를 위해 두 가지 리소스를 사용합니다.
- **PeerAuthentication**: "나에게 오는 트래픽은 mTLS여야 한다"는 수신 정책
- **DestinationRule**: "내가 보내는 트래픽은 mTLS로 보낸다"는 발신 정책

---

## 2. 동작 원리

```text
서비스 A (Envoy)  ──── mTLS ────  서비스 B (Envoy)
     │                                   │
  클라이언트 인증서 제시          서버 인증서 제시
  서버 인증서 검증               클라이언트 인증서 검증
```

Istiod가 각 Pod에 X.509 인증서를 자동 발급하고 갱신합니다. 개발자가 인증서를 직접 관리할 필요가 없습니다.

TLS/mTLS 핸드셰이크를 TCP 3-way handshake처럼 단계별로 이해하려면 [Istio TLS/mTLS 핸드셰이크 동작 원리](./tls-mtls-handshake-flow.md)를 참고합니다.

---

## 3. mTLS 모드

| 모드 | 설명 | 사용 시점 |
|------|------|-----------|
| `STRICT` | mTLS 트래픽만 허용, 평문 거부 | 메시 내 모든 서비스가 Istio 사이드카를 가질 때 |
| `PERMISSIVE` | mTLS와 평문 모두 허용 | 점진적 마이그레이션 중, 기본값 |
| `DISABLE` | mTLS 비활성화 | 특정 서비스만 제외할 때 |

---

## 4. 설정 예시

### 1. 네임스페이스 전체에 STRICT mTLS 적용

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

```bash
kubectl apply -f mtls-strict.yaml
```

### 2. 특정 서비스만 PERMISSIVE (예외 처리)

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: my-app-permissive
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  mtls:
    mode: PERMISSIVE
```

### 3. 발신 트래픽에 mTLS 적용 (DestinationRule)

PeerAuthentication만으로는 부족합니다. 클라이언트 측에서도 mTLS로 보내도록 설정해야 합니다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-mtls
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL   # Istio가 발급한 인증서로 mTLS
```

---

## 5. 현재 mTLS 상태 확인

```bash
# 네임스페이스의 PeerAuthentication 확인
kubectl get peerauthentication -n default

# 특정 Pod 간 mTLS 연결 상태 확인
istioctl x describe pod <pod-name>

# Kiali에서 확인: 서비스 그래프에서 자물쇠 아이콘 표시
istioctl dashboard kiali
```

---

## 6. STRICT 적용 후 검증

```bash
# mTLS 없이 직접 호출 시도 (실패해야 정상)
kubectl run curl-test --image=curlimages/curl -it --rm \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  -- curl http://my-app
# 예상: Connection reset / upstream connect error

# 사이드카가 있는 Pod에서 호출 (성공해야 정상)
kubectl run curl-test --image=curlimages/curl -it --rm -- curl http://my-app
# 예상: 정상 응답
```

---

## 7. 전체 메시에 STRICT 적용

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system   # 모든 네임스페이스에 적용
spec:
  mtls:
    mode: STRICT
```

> **주의**: `istio-system` 네임스페이스에 적용하면 메시 전체에 영향을 줍니다. 사이드카가 없는 Pod가 있다면 통신이 차단됩니다. PERMISSIVE로 시작해서 점진적으로 전환하는 것을 권장합니다.

---

## 8. 참고

- [Istio TLS/mTLS 핸드셰이크 동작 원리](./tls-mtls-handshake-flow.md)
- [공식문서 - PeerAuthentication](https://istio.io/latest/docs/reference/config/security/peer_authentication/)
- [공식문서 - Mutual TLS Migration](https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/)
