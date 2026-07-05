# mTLS 핸드셰이크 실패 심층 디버깅 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

mTLS 핸드셰이크 실패는 503 에러로 나타나지만 원인이 다양함. 인증서 문제, PeerAuthentication 불일치, DestinationRule TLS 모드 충돌, 사이드카 미주입 등 각 원인마다 확인 방법과 해결책이 다름.

이 문서는 mTLS 관련 장애 발생 시 원인을 빠르게 특정하는 진단 흐름과 시나리오별 해결 방법을 정리함.

---

## 2. 진단 흐름

```
503 에러 발생
    │
    ▼
Access Log 응답 플래그 확인
    │
    ├── UF (연결 실패) → mTLS 핸드셰이크 실패 의심
    │
    └── UC (연결 종료) → 인증서 검증 실패 또는 정책 불일치
    │
    ▼
istioctl authn tls-check로 TLS 상태 확인
    │
    ├── CONFLICT → PeerAuthentication vs DestinationRule 불일치
    │
    └── OK인데 에러 → 인증서 유효성 또는 RBAC 문제
    │
    ▼
Envoy SSL 통계 및 인증서 상태 확인
    │
    ▼
istiod 로그에서 인증서 발급 오류 확인
```

---

## 3. 시나리오별 진단 및 해결

### 시나리오 1: CONFLICT — PeerAuthentication vs DestinationRule 불일치

**증상**: `istioctl authn tls-check`에서 STATUS가 CONFLICT

```bash
# TLS 상태 확인
istioctl authn tls-check <CLIENT_POD>.default my-app.default.svc.cluster.local

# CONFLICT 예시 출력
# HOST:PORT                                  STATUS    SERVER   CLIENT  AUTHN POLICY
# my-app.default.svc.cluster.local:8080      CONFLICT  STRICT   HTTP    default/default
```

**원인 해석:**

| SERVER | CLIENT | 의미 |
|--------|--------|------|
| STRICT | HTTP | 서버는 mTLS만 받는데 클라이언트가 평문 전송 |
| PERMISSIVE | ISTIO_MUTUAL | 불일치지만 PERMISSIVE라 동작은 함 |
| STRICT | DISABLE | 완전 충돌 — 즉시 통신 단절 |

```bash
# DestinationRule TLS 모드 확인
kubectl get destinationrule -n default -o yaml | grep -A 10 "trafficPolicy"

# PeerAuthentication 확인
kubectl get peerauthentication -n default -o yaml
kubectl get peerauthentication -n istio-system -o yaml  # 전체 메시 정책
```

**해결:**

```yaml
# DestinationRule TLS 모드를 ISTIO_MUTUAL로 수정
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL    # DISABLE → ISTIO_MUTUAL로 변경
```

---

### 시나리오 2: 인증서 만료 또는 갱신 실패

**증상**: 간헐적으로 503 발생, Envoy 로그에 `certificate expired` 또는 `handshake_failure`

```bash
# 1. 인증서 유효성 확인
istioctl proxy-config secret <POD_NAME> -n default

# VALID CERT 컬럼이 false이거나 NOT AFTER가 과거 시간이면 만료

# 2. 인증서 만료 시간 직접 확인
istioctl proxy-config secret <POD_NAME> -n default -o json | \
  jq -r '.[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -dates

# 3. SSL 핸드셰이크 에러 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "ssl.connection_error"

# 4. istiod 인증서 발급 로그 확인
kubectl logs -n istio-system deployment/istiod | \
  grep -E "cert|CSR|error|expire" | tail -30
```

**해결:**

```bash
# 강제 인증서 갱신: Pod 재시작
kubectl rollout restart deployment/my-app -n default

# istiod 자체 재시작 (마지막 수단)
kubectl rollout restart deployment/istiod -n istio-system
```

---

### 시나리오 3: 사이드카 미주입 클라이언트가 STRICT 서버에 접근

**증상**: 특정 Pod에서만 연결 실패. 해당 Pod에 `istio-proxy` 컨테이너 없음

```bash
# 1. 클라이언트 Pod 사이드카 주입 여부 확인
kubectl get pod <CLIENT_POD> -n default -o jsonpath='{.spec.containers[*].name}'

# 2. 서버의 PeerAuthentication 확인
kubectl get peerauthentication -n default

# 3. 사이드카 없는 Pod 목록 전체 확인
kubectl get pods -n default -o json | \
  jq '.items[] | select(
    [.spec.containers[].name] | index("istio-proxy") | not
  ) | .metadata.name'
```

**해결 방법 선택:**

| 방법 | 적용 상황 |
|------|---------|
| 클라이언트 Pod에 사이드카 주입 | 클라이언트가 관리 가능한 워크로드 |
| 서버에 `portLevelMtls` 예외 처리 | 레거시 클라이언트, 임시 조치 |
| 서버를 PERMISSIVE로 유지 | 장기적으로 사이드카 주입이 불가한 경우 |

```bash
# 사이드카 주입: 네임스페이스 레이블 추가 후 Pod 재시작
kubectl label namespace default istio-injection=enabled
kubectl rollout restart deployment/<CLIENT_DEPLOYMENT> -n default
```

---

### 시나리오 4: 루트 CA 불일치 (다중 클러스터 또는 CA 교체 후)

**증상**: `certificate verify failed` 로그, 동일 클러스터 내에서는 정상이지만 외부 클러스터와 통신 실패

```bash
# 1. 루트 CA 인증서 확인 (두 클러스터의 루트 CA가 같아야 함)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/config_dump | \
  jq '.configs[] | select(."@type" | contains("SecretsConfigDump")) |
      .dynamic_active_secrets[] | select(.name == "ROOTCA") |
      .secret.validationContext.trustedCa.inlineBytes' | \
  tr -d '"' | base64 -d | openssl x509 -noout -subject -issuer

# 2. 양측 ROOTCA 지문 비교
kubectl exec <POD_A> -n default -c istio-proxy -- \
  openssl s_client -connect <POD_B_IP>:15443 2>/dev/null | \
  openssl x509 -noout -fingerprint
```

---

### 시나리오 5: AuthorizationPolicy로 인한 차단 (mTLS 자체는 정상)

**증상**: mTLS는 성공하지만 이후 403 또는 RBAC 거부

```bash
# 1. Access Log에서 403 + rbac 관련 확인
kubectl logs <SERVER_POD> -n default -c istio-proxy | \
  grep "403\|rbac\|denied"

# 2. AuthorizationPolicy dry-run 모드로 영향도 확인
kubectl get authorizationpolicy -n default -o yaml | grep -E "action:|principals:"

# 3. Envoy RBAC 통계 확인
kubectl exec <SERVER_POD> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "rbac"

# rbac.denied: RBAC으로 거부된 요청 수

# 4. 요청의 실제 principal 확인
kubectl exec <SERVER_POD> -n default -c istio-proxy -- \
  curl -s -X POST http://localhost:15000/logging?rbac=debug

kubectl logs <SERVER_POD> -n default -c istio-proxy | grep "principal"

# 로그 레벨 원복
kubectl exec <SERVER_POD> -n default -c istio-proxy -- \
  curl -s -X POST http://localhost:15000/logging?rbac=warning
```

---

## 4. 공통 진단 명령어

### 전체 진단 원라이너

```bash
# 클라이언트 Pod 기준 특정 서비스 mTLS 전체 진단
POD=<CLIENT_POD>
SVC=my-app.default.svc.cluster.local
NS=default

echo "=== TLS Check ===" && \
  istioctl authn tls-check ${POD}.${NS} ${SVC}

echo "=== Secret Status ===" && \
  istioctl proxy-config secret ${POD} -n ${NS}

echo "=== SSL Stats ===" && \
  kubectl exec ${POD} -n ${NS} -c istio-proxy -- \
    curl -s http://localhost:15000/stats | \
    grep -E "ssl\.(handshake|connection_error|fail|session_reused)"

echo "=== Recent Errors ===" && \
  kubectl logs ${POD} -n ${NS} -c istio-proxy --tail=20 | \
  grep -E "ssl|TLS|cert|error"
```

---

## 5. 모니터링 및 확인

```bash
# mTLS 핸드셰이크 성공/실패 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "ssl\.(handshake$|connection_error|fail)"

# RBAC 거부 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "rbac.denied"

# 인증서 상태 모니터링
istioctl proxy-config secret -n default
```

### Prometheus 쿼리

```promql
# mTLS 핸드셰이크 실패율
rate(envoy_listener_ssl_connection_error[5m])

# RBAC 거부율
rate(envoy_http_rbac_denied[5m])
```

---

## 6. TIP

- `istioctl authn tls-check`는 첫 번째 진단 명령어. CONFLICT 여부만 봐도 원인의 80%를 특정할 수 있음
- mTLS 에러와 AuthorizationPolicy 거부는 둘 다 503/403으로 보이지만 원인이 다름. Access Log의 응답 플래그와 서버 사이드카 로그를 함께 확인해 구분
- Envoy는 인증서 갱신을 hot reload로 처리하므로 갱신 자체는 트래픽 중단 없이 진행됨. 단, 갱신 실패 시 기존 인증서 만료 후 통신이 단절됨
- `ssl.session_reused` 수치가 낮으면 매 요청마다 TLS 핸드셰이크가 발생해 지연이 증가할 수 있음. Connection Pool 설정으로 연결 재사용 증가 권장
