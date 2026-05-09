# mTLS 인증서 라이프사이클 & SPIFFE/SVID 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio mTLS는 각 서비스에 SPIFFE (Secure Production Identity Framework For Everyone) 기반의 암호화 신원 (SVID, SPIFFE Verifiable Identity Document)을 발급해 서비스 간 상호 인증을 수행함. 인증서는 istiod가 내장 CA로 발급하며 Envoy 사이드카에 SDS (Secret Discovery Service)를 통해 전달됨.

인증서가 만료되거나 갱신에 실패하면 mTLS 핸드셰이크가 실패해 서비스 간 통신이 단절되므로 라이프사이클 이해가 필수.

---

## 2. 인증서 발급 및 갱신 흐름

### 전체 흐름

```
[Pod 시작]
    │
    ▼
istio-proxy (Envoy) 시작
    │  CSR (Certificate Signing Request) 생성
    │  서비스 어카운트 토큰 첨부
    ▼
istiod (CA)
    │  토큰 검증 → SPIFFE ID 기반 인증서 발급
    │  루트 CA로 서명
    ▼
SDS (Secret Discovery Service)
    │  gRPC로 Envoy에 인증서 전달 (디스크 저장 안 함)
    ▼
Envoy
    │  인증서 메모리 보관
    │  만료 전 자동 갱신 요청 (기본: 만료 50% 시점)
    ▼
[서비스 간 mTLS 핸드셰이크]
```

---

### SPIFFE ID 구조

Istio는 쿠버네티스 서비스 어카운트 (ServiceAccount)를 기반으로 SPIFFE ID를 부여함.

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>

# 예시
spiffe://cluster.local/ns/default/sa/my-app
```

| 구성 요소 | 값 | 의미 |
|----------|-----|------|
| `trust-domain` | `cluster.local` | 클러스터 식별자 (MeshConfig로 변경 가능) |
| `ns` | `default` | 네임스페이스 |
| `sa` | `my-app` | ServiceAccount 이름 |

**SPIFFE ID 확인:**

```bash
# 실제 발급된 인증서의 SAN (Subject Alternative Name) 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  openssl s_client -connect localhost:15443 2>/dev/null | \
  openssl x509 -noout -text | grep "URI:"

# 또는 istioctl로 확인
istioctl proxy-config secret <POD_NAME> -n default -o json | \
  jq '.[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  tr -d '"' | base64 -d | openssl x509 -noout -text | grep "URI:"
```

---

### 인증서 구성

Istio는 각 사이드카에 아래 3가지 비밀 (Secret)을 SDS로 전달함.

| SDS 이름 | 내용 | 용도 |
|----------|------|------|
| `default` | 서비스 인증서 + 개인키 | mTLS 핸드셰이크 시 본인 증명 |
| `ROOTCA` | 루트 CA 인증서 | 상대방 인증서 검증 |
| `kubernetes-gateway-ca-cert` | (Gateway 한정) | Gateway TLS 처리 |

```bash
# SDS 비밀 목록 확인
istioctl proxy-config secret <POD_NAME> -n default

# 예시 출력
# RESOURCE NAME   TYPE           STATUS     VALID CERT  SERIAL NUMBER  NOT AFTER
# default         Cert Chain     ACTIVE     true        123456         2026-05-10T18:00:00Z
# ROOTCA          CA             ACTIVE     true        654321         2036-01-01T00:00:00Z
```

---

### 인증서 갱신 메커니즘

```bash
# 인증서 유효 기간 확인 (기본 24시간)
kubectl get configmap istio -n istio-system -o yaml | grep -E "defaultConfig|proxyMetadata" -A 5

# 갱신 시점: 만료까지 남은 시간의 50% 시점 (기본)
# 예: 24시간 인증서 → 12시간 후 갱신 요청

# 인증서 만료 시간 직접 확인
istioctl proxy-config secret <POD_NAME> -n default -o json | \
  jq '.[].secret.tlsCertificate.certificateChain | .inlineBytes' | \
  tr -d '"' | base64 -d | openssl x509 -noout -dates
```

**인증서 유효 기간 커스터마이징:**

```yaml
# istiod 환경 변수로 조정
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istiod
  namespace: istio-system
spec:
  template:
    spec:
      containers:
        - name: discovery
          env:
            - name: CITADEL_WORKLOAD_CERT_TTL
              value: "48h"          # 인증서 유효 기간 (기본: 24h)
            - name: CITADEL_WORKLOAD_CERT_MIN_GRACE_PERIOD
              value: "1h"           # 갱신 시작 최소 여유 시간
```

---

### istiod CA 인증서 구조

```bash
# istiod 루트 CA 인증서 확인
kubectl get secret istio-ca-secret -n istio-system -o yaml | \
  grep "ca-cert.pem" | awk '{print $2}' | base64 -d | \
  openssl x509 -noout -text | grep -E "Subject:|Not After"

# 루트 CA 유효 기간 (기본 10년)
# 루트 CA 갱신은 자동이 아님 — 별도 절차 필요
```

---

## 3. 트러블슈팅

### 증상: mTLS 핸드셰이크 실패, `ssl.handshake_error` 급증

#### 원인
인증서 만료 또는 갱신 실패로 유효하지 않은 인증서로 핸드셰이크 시도

#### 해결 방법

```bash
# 1. 인증서 유효성 확인
istioctl proxy-config secret <POD_NAME> -n default

# VALID CERT가 false이면 만료 또는 갱신 실패

# 2. 갱신 실패 원인 확인 (istiod 로그)
kubectl logs -n istio-system deployment/istiod | grep -E "cert|CSR|error" | tail -30

# 3. Envoy와 istiod 간 SDS 연결 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "sds"

# 4. 강제 갱신: Pod 재시작으로 새 인증서 발급
kubectl rollout restart deployment/my-app -n default

# 5. istiod가 ServiceAccount 토큰을 읽을 수 있는지 확인
kubectl get serviceaccount my-app -n default
kubectl get rolebinding -n default | grep my-app
```

---

### 증상: 신규 Pod가 시작되자마자 연결 거부됨 (초기화 레이스 컨디션)

#### 원인
Envoy가 istiod로부터 인증서를 수신하기 전에 트래픽이 들어옴

#### 해결 방법

```bash
# holdApplicationUntilProxyStarts 설정 (Envoy가 준비될 때까지 앱 시작 대기)
kubectl edit configmap istio -n istio-system
```

```yaml
# istio ConfigMap 내 defaultConfig 수정
data:
  mesh: |-
    defaultConfig:
      holdApplicationUntilProxyStarts: true   # 앱 컨테이너 시작 전 Envoy 준비 대기
```

---

## 4. 모니터링 및 확인

```bash
# 클러스터 전체 인증서 만료 현황 확인
istioctl proxy-config secret -n default --all-namespaces | \
  grep -v "ACTIVE\|ROOTCA"

# SSL 핸드셰이크 통계 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "ssl\.(handshake|fail|session_reused|connection_error)"

# istiod CA 상태 확인
kubectl get pods -n istio-system -l app=istiod
kubectl logs -n istio-system deployment/istiod | grep -i "cert\|CA" | tail -20
```

### Prometheus 쿼리

```promql
# 인증서 만료까지 남은 시간 (초)
min by (pod, namespace) (
  envoy_server_days_until_first_cert_expiring * 86400
)

# SSL 핸드셰이크 에러율
rate(envoy_listener_ssl_connection_error[5m])
```

---

## 5. TIP

- SDS를 사용하므로 인증서가 디스크에 저장되지 않음. `kubectl exec`로 파일 시스템에서 PEM 파일을 찾으려 하면 없음
- ServiceAccount를 공유하는 여러 Deployment는 동일한 SPIFFE ID를 가짐 → AuthorizationPolicy에서 ServiceAccount 단위 접근 제어 시 이 점 주의
- 루트 CA 인증서 교체 (rotation)는 자동이 아니므로 10년 만료 전 별도 절차 필요. 이를 위해 외부 CA (Vault, AWS PCA) 연동을 고려
- `PILOT_CERT_PROVIDER=istiod`(기본)를 `PILOT_CERT_PROVIDER=kubernetes`로 변경하면 쿠버네티스 내장 CA를 사용 가능하나 권장하지 않음 (갱신 제어 불가)
