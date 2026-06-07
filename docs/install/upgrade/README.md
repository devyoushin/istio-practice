# Istio 업그레이드 실행 방법

Istio 업그레이드의 상세 전략은 [istio-upgrade.md](../istio-upgrade.md)를 기준으로 합니다. 이 문서는 저장소의 Helm 업그레이드 스크립트를 실행하는 절차만 따로 정리합니다.

## 1. 사전 점검

```bash
export TARGET_VERSION="1.28.3"
export ISTIO_NAMESPACE="istio-system"
export INGRESS_NAMESPACE="istio-ingress"

istioctl version
istioctl proxy-status
istioctl analyze -A
kubectl get pods -n ${ISTIO_NAMESPACE}
kubectl get pods -n ${INGRESS_NAMESPACE}
```

현재 values를 보관합니다.

```bash
helm get values istiod -n ${ISTIO_NAMESPACE} > istiod-values-before-upgrade.yaml
helm get values istio-ingress -n ${INGRESS_NAMESPACE} > ingress-values-before-upgrade.yaml
```

## 2. Helm 업그레이드

이 저장소의 실행 스크립트를 사용합니다.

```bash
TARGET_VERSION=${TARGET_VERSION} \
ISTIO_NAMESPACE=${ISTIO_NAMESPACE} \
INGRESS_NAMESPACE=${INGRESS_NAMESPACE} \
./ops/upgrade/upgrade-istio-helm.sh
```

직접 실행하려면 아래 흐름을 따릅니다.

```bash
helm repo update istio

helm upgrade istio-base istio/base \
  --namespace ${ISTIO_NAMESPACE} \
  --version ${TARGET_VERSION} \
  --set defaultRevision=default

helm upgrade istiod istio/istiod \
  --namespace ${ISTIO_NAMESPACE} \
  --version ${TARGET_VERSION} \
  --values ops/install/istiod-values.yaml \
  --wait

helm upgrade istio-ingress istio/gateway \
  --namespace ${INGRESS_NAMESPACE} \
  --version ${TARGET_VERSION} \
  --values ops/install/ingress-gateway-values.yaml \
  --wait
```

## 3. 확인

```bash
istioctl version
istioctl proxy-status
istioctl analyze -A
kubectl get pods -n ${ISTIO_NAMESPACE}
kubectl get pods -n ${INGRESS_NAMESPACE}
```

컨트롤 플레인 업그레이드 후 기존 워크로드의 사이드카는 자동으로 교체되지 않습니다. 필요한 네임스페이스부터 `kubectl rollout restart deployment -n <NAMESPACE>`로 데이터 플레인을 순차 갱신합니다.

## 4. 롤백

```bash
helm history istiod -n ${ISTIO_NAMESPACE}
helm rollback istiod <REVISION> -n ${ISTIO_NAMESPACE} --wait

helm history istio-ingress -n ${INGRESS_NAMESPACE}
helm rollback istio-ingress <REVISION> -n ${INGRESS_NAMESPACE} --wait
```

프로덕션에서는 [istio-upgrade.md](../istio-upgrade.md)의 canary revision 방식이 더 안전합니다.
