# Istio 버전 업그레이드 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3 → 차기 버전
> **환경**: EKS

---

## 1. 개요

Istio 업그레이드는 컨트롤 플레인 (istiod)과 데이터 플레인 (Envoy 사이드카)을 분리해서 진행함. 업그레이드 방식에 따라 서비스 중단 없이 순차적으로 전환하는 **Canary 업그레이드**와 기존 버전을 직접 교체하는 **In-place 업그레이드**가 있음.

### 업그레이드 방식 비교

| 방식 | 다운타임 | 안전성 | 적합한 환경 |
|------|---------|--------|-----------|
| **Canary 업그레이드** | 없음 | 높음 (롤백 용이) | 프로덕션 |
| **In-place 업그레이드** | 짧게 발생 가능 | 낮음 (롤백 복잡) | 개발/스테이징 |

---

## 2. 업그레이드 전 사전 점검

```bash
# 1. 현재 Istio 버전 확인
istioctl version
kubectl get pods -n istio-system -o yaml | grep "image:" | grep "istio"

# 2. 현재 설정 백업
kubectl get istio-system -o yaml > istio-backup.yaml
kubectl get vs,dr,gw,se,ap,pa -A -o yaml > istio-resources-backup.yaml

# 3. Envoy 버전과 istiod 버전 동기화 상태 확인
istioctl proxy-status

# 4. 업그레이드 전 구성 검증
istioctl analyze -n default --all-namespaces

# 5. 차기 버전 릴리즈 노트 확인
# https://istio.io/latest/news/releases/
# 제거(Deprecated)된 API 및 Breaking Change 확인 필수
```

---

## 3. Canary 업그레이드 (프로덕션 권장)

새 버전의 istiod를 별도 revision으로 배포하고, 워크로드를 순차적으로 마이그레이션함. 두 버전이 공존하는 기간이 있어 문제 발생 시 즉시 롤백 가능.

### 1단계: 신규 revision으로 istiod 배포

```bash
# 신규 버전 istioctl 다운로드
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=<NEW_VERSION> sh -
export PATH=$PATH:./istio-<NEW_VERSION>/bin

# 기존 설치를 유지하면서 새 revision 배포
# revision 이름은 버전에서 . 을 - 로 변환
istioctl install --set revision=1-29-0 -y

# 두 버전의 istiod가 동시에 실행됨
kubectl get pods -n istio-system | grep istiod
# istiod-xxx (기존: revision=default)
# istiod-1-29-0-xxx (신규)
```

### 2단계: 개별 네임스페이스 마이그레이션

```bash
# 테스트 네임스페이스부터 시작
# 기존 레이블 제거 후 신규 revision 레이블 추가
kubectl label namespace test-ns istio-injection-   # 기존 레이블 제거
kubectl label namespace test-ns istio.io/rev=1-29-0  # 신규 revision 지정

# Pod 재시작으로 새 버전 사이드카 주입
kubectl rollout restart deployment -n test-ns

# 사이드카 버전 확인
kubectl get pods -n test-ns -o yaml | grep "istio-proxy" -A 2 | grep "image:"

# 정상 동작 확인 후 프로덕션 네임스페이스 적용
kubectl label namespace default istio-injection-
kubectl label namespace default istio.io/rev=1-29-0
kubectl rollout restart deployment -n default
```

### 3단계: 기존 istiod 제거

```bash
# 모든 워크로드가 신규 버전으로 전환됐는지 확인
istioctl proxy-status | grep "STALE\|NOT SENT"

# 기존 revision 제거
istioctl uninstall --revision default -y

# 또는 Helm으로 관리하는 경우
helm uninstall istiod-default -n istio-system
```

---

## 4. In-place 업그레이드 (개발/스테이징)

기존 버전을 직접 신규 버전으로 교체.

```bash
# 1. 새 버전 istioctl로 기존 설치 업그레이드
istioctl upgrade -y

# 2. 컨트롤 플레인 업그레이드 확인
kubectl get pods -n istio-system
istioctl version

# 3. 데이터 플레인 (사이드카) 업그레이드
# 각 워크로드 Pod 재시작 필요
kubectl rollout restart deployment -n default

# 4. Gateway 업그레이드
kubectl rollout restart deployment/istio-ingressgateway -n istio-system
```

---

## 5. 데이터 플레인 업그레이드

컨트롤 플레인 업그레이드 후 사이드카는 **Pod 재시작 시 자동으로 새 버전**으로 교체됨. 기존 Pod는 구 버전 사이드카를 계속 사용함.

```bash
# 네임스페이스별 순서대로 롤링 재시작
kubectl rollout restart deployment -n default
kubectl rollout restart deployment -n app-ns-1
kubectl rollout restart deployment -n app-ns-2

# DaemonSet 형태의 워크로드
kubectl rollout restart daemonset -n default

# 특정 워크로드만 우선 업그레이드 (중요도 낮은 것부터)
kubectl rollout restart deployment/my-app-worker -n default

# 업그레이드 진행 상황 확인
kubectl rollout status deployment/my-app -n default
```

---

## 6. 롤백 방법

### Canary 업그레이드 롤백

```bash
# 워크로드를 구 버전 revision으로 복구
kubectl label namespace default istio.io/rev-       # 신규 revision 제거
kubectl label namespace default istio-injection=enabled  # 기존 방식 복구
kubectl rollout restart deployment -n default

# 신규 istiod 제거
istioctl uninstall --revision 1-29-0 -y
```

### In-place 업그레이드 롤백

```bash
# 구 버전 istioctl로 재설치
./istio-<OLD_VERSION>/bin/istioctl install -y

# 사이드카 재시작으로 구 버전 주입
kubectl rollout restart deployment -n default
```

---

## 7. 트러블슈팅

### 증상: 업그레이드 후 일부 Pod에서 503

#### 원인
컨트롤 플레인은 신규 버전, 사이드카는 구 버전으로 xDS 호환성 문제

#### 해결 방법

```bash
# 1. 버전 불일치 Pod 확인
istioctl proxy-status | grep -v "SYNCED"

# 2. 해당 Pod 재시작으로 신규 사이드카 주입
kubectl rollout restart deployment/<AFFECTED_DEPLOYMENT> -n default

# 3. istiod 로그에서 호환성 오류 확인
kubectl logs -n istio-system deployment/istiod | grep -i "version\|compat"
```

---

### 증상: 업그레이드 후 istioctl analyze에서 Deprecated API 경고

#### 원인
이전 버전에서 사용하던 `v1alpha3` API가 새 버전에서 제거됨

#### 해결 방법

```bash
# 사용 중인 Deprecated API 확인
istioctl analyze --all-namespaces 2>&1 | grep "Deprecated"

# v1alpha3 → v1beta1 마이그레이션
kubectl get virtualservice -A -o yaml | grep "apiVersion"
# networking.istio.io/v1alpha3 → networking.istio.io/v1beta1 로 변경 후 재적용
```

---

## 8. 모니터링 및 확인

```bash
# 전체 버전 현황 확인
istioctl version

# 데이터 플레인 버전 분포 확인 (혼재 여부)
istioctl proxy-status | awk '{print $NF}' | sort | uniq -c

# 업그레이드 후 전체 동기화 상태
istioctl proxy-status | grep -v SYNCED

# Istio 구성 검증
istioctl analyze --all-namespaces
```

---

## 9. TIP

- Istio는 컨트롤 플레인 ±1 버전의 데이터 플레인을 지원함. 업그레이드 중 두 버전이 혼재해도 정상 동작
- 프로덕션에서는 반드시 Canary 업그레이드 사용. In-place는 롤백이 복잡하고 위험
- 마이너 버전 업그레이드 (1.27 → 1.28)도 Canary 방식 권장. 패치 버전 (1.28.2 → 1.28.3)은 In-place로 진행 가능
- EKS 업그레이드와 Istio 업그레이드를 동시에 진행하지 말 것. 각각 검증 후 순차 진행
- 업그레이드 전 `istioctl x precheck` 명령으로 사전 호환성 검사 실행
