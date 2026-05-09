# mTLS PERMISSIVE → STRICT 마이그레이션 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

운영 중인 클러스터에서 mTLS를 PERMISSIVE(평문 허용)에서 STRICT(mTLS 강제)로 전환할 때 잘못된 순서로 적용하면 사이드카가 없는 클라이언트나 레거시 서비스의 통신이 즉시 단절됨.

이 문서는 서비스 중단 없이 단계적으로 STRICT를 적용하는 전략과 각 단계에서 확인해야 할 사항을 정리함.

### PERMISSIVE vs STRICT 차이

| 항목 | PERMISSIVE | STRICT |
|------|-----------|--------|
| mTLS 트래픽 | 수락 | 수락 |
| 평문(plaintext) 트래픽 | 수락 | 거부 (즉시 RST) |
| 사이드카 없는 클라이언트 | 통신 가능 | 통신 불가 |
| 보안 수준 | 중간 (전환기) | 높음 (Zero Trust) |

---

## 2. 마이그레이션 전략

### 전환 단계 개요

```
[1단계] 현황 파악
  → 사이드카 미주입 Pod, 외부 클라이언트 목록 확보

[2단계] 네임스페이스 단위 STRICT 전환 (트래픽 확인하며 점진 적용)
  → 낮은 위험도 네임스페이스부터 시작

[3단계] 서비스 단위 검증
  → 각 서비스 정상 동작 확인

[4단계] 전체 메시 STRICT (MeshConfig 적용)
  → 모든 네임스페이스 커버
```

---

### 1단계: 현황 파악

```bash
# 사이드카 미주입 Pod 목록 확인 (istio-proxy 컨테이너 없는 Pod)
kubectl get pods -A -o json | \
  jq '.items[] | select(.spec.containers[].name != "istio-proxy") |
      {namespace: .metadata.namespace, name: .metadata.name}' | \
  jq -s 'unique_by(.name)'

# 네임스페이스별 사이드카 주입 레이블 확인
kubectl get namespaces --show-labels | grep "istio-injection"

# 현재 PeerAuthentication 정책 확인
kubectl get peerauthentication -A

# PERMISSIVE 트래픽 실제 발생 여부 확인 (평문 트래픽이 있는지)
istioctl x authz check <POD_NAME> -n default
```

---

### 2단계: 네임스페이스 단위 STRICT 전환

#### 전환 전 — tls-check로 사전 영향도 파악

```bash
# 특정 서비스에 연결하는 클라이언트들의 TLS 상태 일괄 확인
istioctl authn tls-check -n default

# 예시 출력
# HOST:PORT                                   STATUS    SERVER        CLIENT       AUTHN POLICY
# my-app.default.svc.cluster.local:8080       OK        PERMISSIVE    ISTIO_MUTUAL default/
# legacy-app.default.svc.cluster.local:8080   CONFLICT  STRICT        HTTP         legacy-pa

# STATUS가 CONFLICT인 서비스는 STRICT 전환 시 즉시 통신 단절
```

#### STRICT 적용 (네임스페이스 단위)

```yaml
# 특정 네임스페이스만 STRICT 적용
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: default       # 이 네임스페이스에만 적용
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl apply -f peerauthentication-strict.yaml
```

#### 적용 직후 검증

```bash
# mTLS 상태 재확인
istioctl authn tls-check -n default

# 에러 발생 여부 확인
kubectl logs <POD_NAME> -n default -c istio-proxy | grep -E "ssl|TLS|handshake" | tail -20

# 서비스 응답 정상 여부 확인
kubectl exec <CLIENT_POD> -n default -c <APP_CONTAINER> -- \
  curl -s -o /dev/null -w "%{http_code}" http://my-app:8080/health
```

---

### 3단계: 서비스 단위 예외 처리

STRICT 적용 후 특정 서비스만 일시적으로 PERMISSIVE를 유지해야 하는 경우 (레거시 클라이언트 등).

```yaml
# 특정 Pod만 PERMISSIVE 유지
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: legacy-app-permissive
  namespace: default
spec:
  selector:
    matchLabels:
      app: legacy-app       # 이 Pod만 PERMISSIVE 유지
  mtls:
    mode: PERMISSIVE
```

**포트 단위 예외 처리 (더 세밀한 제어):**

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: my-app-port-exception
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  mtls:
    mode: STRICT
  portLevelMtls:
    9090:               # 특정 포트만 PERMISSIVE (예: Prometheus 스크래핑 포트)
      mode: PERMISSIVE
```

---

### 4단계: 전체 메시 STRICT

모든 네임스페이스를 검증한 후 메시 전체에 STRICT 적용.

```yaml
# 전체 메시 STRICT (istio-system 네임스페이스에 배포)
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system   # 전체 메시에 적용
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl apply -f mesh-strict.yaml

# 전체 네임스페이스 tls-check
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $ns ==="
  istioctl authn tls-check -n $ns 2>/dev/null | grep -v "OK"
done
```

---

### 롤백 방법

문제 발생 시 즉시 PERMISSIVE로 복구.

```bash
# 네임스페이스 단위 롤백
kubectl patch peerauthentication default -n default \
  --type merge -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'

# 전체 메시 롤백
kubectl patch peerauthentication default -n istio-system \
  --type merge -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'

# 또는 완전 삭제 (메시 기본값인 PERMISSIVE로 복귀)
kubectl delete peerauthentication default -n default
```

---

## 3. 트러블슈팅

### 증상: STRICT 적용 후 특정 서비스만 503

#### 원인
해당 서비스에 사이드카가 없거나 DestinationRule의 TLS 모드가 ISTIO_MUTUAL이 아님

#### 해결 방법

```bash
# 1. 서버 Pod 사이드카 주입 여부 확인
kubectl get pod <SERVER_POD> -n default -o yaml | grep "istio-proxy"

# 2. 클라이언트 → 서버 TLS 상태 확인
istioctl authn tls-check <CLIENT_POD>.default my-app.default.svc.cluster.local

# STATUS가 CONFLICT이면 DestinationRule TLS 모드 확인
kubectl get destinationrule -n default -o yaml | grep -A 5 "tls:"

# 3. DestinationRule이 없으면 Istio가 자동으로 ISTIO_MUTUAL 사용
# DestinationRule이 있고 tls.mode: DISABLE이면 STRICT와 충돌
```

---

### 증상: Prometheus 스크래핑 실패 (STRICT 적용 후)

#### 원인
Prometheus가 사이드카 없이 메트릭 수집을 시도하면 STRICT 정책에 의해 거부됨

#### 해결 방법

```yaml
# Prometheus 스크래핑 포트(15090)만 PERMISSIVE 예외 처리
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: metrics-permissive
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  mtls:
    mode: STRICT
  portLevelMtls:
    15090:
      mode: PERMISSIVE
```

---

## 4. 모니터링 및 확인

```bash
# 전체 네임스페이스 TLS 상태 일괄 확인
istioctl authn tls-check -n default

# STRICT 적용 후 평문 트래픽 거부 통계 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "ssl_error\|no_filter_chain_match"

# 현재 적용된 PeerAuthentication 전체 목록
kubectl get peerauthentication -A

# Istio 구성 오류 분석
istioctl analyze -n default
```

### Prometheus 쿼리

```promql
# STRICT 전환 후 mTLS 트래픽 비율 확인
sum(rate(istio_requests_total{
  connection_security_policy="mutual_tls",
  destination_service_namespace="default"
}[5m])) /
sum(rate(istio_requests_total{
  destination_service_namespace="default"
}[5m]))

# 1.0에 가까울수록 전체 트래픽이 mTLS로 전환됨
```

---

## 5. TIP

- STRICT 전환 전 반드시 `istioctl authn tls-check`로 CONFLICT 서비스를 먼저 파악. CONFLICT 상태로 STRICT 적용 시 즉시 통신 단절
- 헬스체크 엔드포인트는 kubelet이 사이드카 없이 직접 호출하므로 STRICT 적용 시 실패할 수 있음. Istio 1.9+는 자동으로 헬스체크 포트를 제외하지만, 구버전은 `portLevelMtls`로 수동 예외 처리 필요
- 전환 순서 권장: `개발 네임스페이스 → 스테이징 → 프로덕션 저위험 서비스 → 프로덕션 전체`
- 전체 메시 STRICT 정책 (`istio-system` 기준)보다 네임스페이스별 정책이 우선 적용됨. 예외 네임스페이스는 별도 PERMISSIVE 정책 유지 가능
