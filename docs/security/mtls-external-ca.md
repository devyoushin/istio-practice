# mTLS 외부 CA 연동 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio 기본 설정은 istiod 내장 CA (자체 서명 루트 CA)를 사용함. 기업 환경에서는 보안 정책상 인증서 발급 권한을 중앙 PKI 인프라에서 관리해야 하는 경우가 많음.

외부 CA를 연동하면 istiod가 루트 CA 역할 대신 중간 CA (Intermediate CA)로 동작하며, 실제 서명 권한은 외부 CA가 보유함.

### 연동 방식 비교

| 방식 | 구현 난이도 | 사용 시점 |
|------|-----------|---------|
| **플러그인 CA** (cacerts Secret) | 낮음 | 자체 CA 인증서를 직접 주입 |
| **AWS ACM PCA** | 중간 | EKS 환경에서 AWS PKI 사용 |
| **HashiCorp Vault** | 높음 | 엔터프라이즈 시크릿 관리 통합 |
| **cert-manager** | 중간 | 쿠버네티스 네이티브 인증서 관리 |

---

## 2. 방식별 설정

### 방식 A: 플러그인 CA (cacerts Secret) — 가장 단순

자체 CA 인증서와 키를 `istio-system` 네임스페이스의 `cacerts` Secret으로 주입하면 istiod가 해당 CA로 워크로드 인증서를 발급함.

#### 사전 준비: 중간 CA 인증서 생성

```bash
# 1. 루트 CA 생성 (보안 환경에서 오프라인으로 생성 권장)
openssl genrsa -out root-key.pem 4096
openssl req -new -x509 -days 3650 -key root-key.pem \
  -subj "/O=My Org/CN=Root CA" -out root-cert.pem

# 2. 중간 CA 키 및 CSR 생성
openssl genrsa -out ca-key.pem 4096
openssl req -new -key ca-key.pem \
  -subj "/O=My Org/CN=Istio Intermediate CA" -out ca-cert.csr

# 3. 루트 CA로 중간 CA 서명
cat > ca-ext.conf << EOF
[v3_ca]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF

openssl x509 -req -days 730 -CA root-cert.pem -CAkey root-key.pem \
  -CAcreateserial -in ca-cert.csr \
  -extfile ca-ext.conf -extensions v3_ca \
  -out ca-cert.pem

# 4. 체인 인증서 생성
cat ca-cert.pem root-cert.pem > cert-chain.pem
```

#### cacerts Secret 생성 및 적용

```bash
# 기존 istiod CA Secret 교체 (istiod 시작 전에 생성해야 함)
kubectl create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem \
  --from-file=ca-key.pem \
  --from-file=root-cert.pem \
  --from-file=cert-chain.pem

# istiod 재시작으로 새 CA 로드
kubectl rollout restart deployment/istiod -n istio-system

# 기존 워크로드 인증서 갱신 (새 CA로 재발급)
kubectl rollout restart deployment/my-app -n default
```

#### 적용 확인

```bash
# 발급된 인증서의 발급자 확인 (외부 CA 이름이 나와야 함)
istioctl proxy-config secret <POD_NAME> -n default -o json | \
  jq -r '.[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -issuer -subject

# 예시 출력
# issuer=O=My Org, CN=Istio Intermediate CA
# subject=spiffe://cluster.local/ns/default/sa/my-app
```

---

### 방식 B: AWS ACM Private CA (EKS 환경 권장)

AWS Certificate Manager Private Certificate Authority를 Istio CA로 연동. EKS 환경에서 AWS PKI 정책을 준수해야 할 때 사용.

#### 사전 요구사항

- AWS ACM PCA 생성 및 활성화 완료
- EKS 노드 IAM Role에 `acm-pca:IssueCertificate`, `acm-pca:GetCertificate` 권한 부여

#### aws-privateca-issuer 설치

```bash
# cert-manager 설치 (의존성)
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set installCRDs=true

# AWS PCA Issuer 설치
helm repo add aws-pca-issuer https://cert-manager.github.io/aws-privateca-issuer
helm install aws-pca-issuer aws-pca-issuer/aws-privateca-issuer \
  -n cert-manager
```

#### AWSPCAClusterIssuer 설정

```yaml
apiVersion: awspca.cert-manager.io/v1beta1
kind: AWSPCAClusterIssuer
metadata:
  name: istio-ca-issuer
spec:
  arn: arn:aws:acm-pca:<REGION>:<ACCOUNT_ID>:certificate-authority/<CA_ID>
  region: <REGION>
```

#### Istio 중간 CA 인증서 요청

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  isCA: true
  duration: 720h          # 30일
  renewBefore: 360h       # 15일 전 갱신
  secretName: cacerts     # istiod가 읽는 Secret 이름
  commonName: istio-ca
  subject:
    organizations:
      - My Org
  privateKey:
    algorithm: RSA
    size: 4096
  issuerRef:
    group: awspca.cert-manager.io
    kind: AWSPCAClusterIssuer
    name: istio-ca-issuer
  usages:
    - cert sign
    - crl sign
    - server auth
    - client auth
```

```bash
kubectl apply -f istio-ca-certificate.yaml

# cert-manager가 cacerts Secret 자동 생성 확인
kubectl get secret cacerts -n istio-system

# istiod 재시작으로 새 CA 적용
kubectl rollout restart deployment/istiod -n istio-system
```

---

### 방식 C: HashiCorp Vault

엔터프라이즈 환경에서 Vault PKI Secrets Engine을 Istio CA로 연동.

#### Vault PKI 설정

```bash
# Vault PKI Secrets Engine 활성화
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki

# 루트 CA 생성
vault write pki/root/generate/internal \
  common_name="Vault Root CA" \
  ttl=87600h

# 중간 CA 경로 설정
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int

# 중간 CA CSR 생성
vault write pki_int/intermediate/generate/internal \
  common_name="Istio Intermediate CA" \
  ttl=43800h > /tmp/pki_int.csr

# 루트 CA로 서명
vault write pki/root/sign-intermediate \
  csr=@/tmp/pki_int.csr \
  format=pem_bundle \
  ttl=43800h > /tmp/signed_cert.pem

# 서명된 중간 CA 설정
vault write pki_int/intermediate/set-signed \
  certificate=@/tmp/signed_cert.pem

# Istio용 발급 Role 생성
vault write pki_int/roles/istio-ca \
  allowed_domains="cluster.local" \
  allow_subdomains=true \
  max_ttl=72h \
  require_cn=false \
  allowed_uri_sans="spiffe://cluster.local/*"
```

#### Vault Agent Injector로 cacerts 자동 주입

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istiod
  namespace: istio-system
  annotations:
    vault.hashicorp.com/role: "istio-ca"
---
# istiod Deployment에 Vault 어노테이션 추가
# (Helm values로 적용)
```

---

## 3. 트러블슈팅

### 증상: cacerts Secret 적용 후 istiod가 기존 자체 CA 사용

#### 원인
istiod 재시작 전 Secret이 마운트되지 않았거나 Secret 키 이름이 올바르지 않음

#### 해결 방법

```bash
# 1. cacerts Secret 키 이름 확인 (정확히 4개 키가 있어야 함)
kubectl get secret cacerts -n istio-system -o yaml | grep "^  "
# ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem 이 있어야 함

# 2. istiod 로그에서 CA 로드 확인
kubectl logs -n istio-system deployment/istiod | grep -i "ca\|cacerts\|loaded"

# 3. istiod 재시작
kubectl rollout restart deployment/istiod -n istio-system

# 4. 발급 인증서 발급자 확인
istioctl proxy-config secret <POD_NAME> -n default -o json | \
  jq -r '.[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -issuer
```

---

### 증상: 외부 CA 교체 후 기존 워크로드와 신규 워크로드 간 mTLS 실패

#### 원인
루트 CA가 변경되면 기존 ROOTCA 인증서와 신규 ROOTCA 인증서가 서로를 신뢰하지 않음

#### 해결 방법

```bash
# 모든 워크로드를 새 CA 인증서로 갱신
kubectl rollout restart deployment -n default
kubectl rollout restart deployment -n <OTHER_NAMESPACE>

# 갱신 완료 후 인증서 발급자 통일 여부 확인
for pod in $(kubectl get pods -n default -o name | head -5); do
  echo "=== $pod ==="
  istioctl proxy-config secret ${pod#pod/} -n default | grep -E "VALID|NOT AFTER"
done
```

---

## 4. 모니터링 및 확인

```bash
# 현재 사용 중인 CA 확인
kubectl logs -n istio-system deployment/istiod | grep "CA provider"

# 인증서 발급자 일괄 확인
kubectl get pods -n default -o name | while read pod; do
  podname=${pod#pod/}
  issuer=$(istioctl proxy-config secret ${podname} -n default -o json 2>/dev/null | \
    jq -r '.[0].secret.tlsCertificate.certificateChain.inlineBytes // empty' | \
    base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
  echo "${podname}: ${issuer}"
done

# cert-manager 사용 시 인증서 갱신 상태
kubectl get certificate -n istio-system
kubectl get certificaterequest -n istio-system
```

---

## 5. TIP

- 플러그인 CA (cacerts Secret) 방식은 설정이 가장 단순하지만 CA 키가 쿠버네티스 Secret에 저장됨. RBAC으로 접근 제한 필요
- EKS 환경에서는 AWS ACM PCA 연동이 가장 운영 부담이 낮음. CA 키가 AWS 인프라에서 관리되므로 키 노출 위험 없음
- 외부 CA 전환 시 기존 자체 서명 루트 CA와 새 루트 CA를 동시에 신뢰하는 과도기가 필요함. `cert-chain.pem`에 두 루트 CA를 모두 포함하면 전환 중 통신 단절 방지 가능
- Vault 연동은 강력하지만 Vault 가용성이 Istio 인증서 갱신에 영향을 줌. Vault 장애 시 인증서 갱신 불가로 연쇄 장애 발생 가능 — Vault HA 구성 필수
- cacerts Secret 교체 후 istiod만 재시작하면 신규 Pod는 새 CA 인증서를 받지만, 기존 Pod는 다음 갱신 주기(약 12시간)까지 구 CA 인증서 사용. 즉시 전환이 필요하면 모든 워크로드 재시작 필요
