#!/usr/bin/env bash
set -euo pipefail

TARGET_VERSION="${TARGET_VERSION:?set TARGET_VERSION, e.g. 1.28.3}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-istio-ingress}"

echo "Pre-check"
istioctl analyze -A
kubectl get pods -n "${ISTIO_NAMESPACE}"
kubectl get pods -n "${INGRESS_NAMESPACE}"

helm repo update istio

helm upgrade istio-base istio/base \
  --namespace "${ISTIO_NAMESPACE}" \
  --version "${TARGET_VERSION}" \
  --set defaultRevision=default

helm upgrade istiod istio/istiod \
  --namespace "${ISTIO_NAMESPACE}" \
  --version "${TARGET_VERSION}" \
  --values "$(dirname "$0")/../install/istiod-values.yaml" \
  --wait

helm upgrade istio-ingress istio/gateway \
  --namespace "${INGRESS_NAMESPACE}" \
  --version "${TARGET_VERSION}" \
  --values "$(dirname "$0")/../install/ingress-gateway-values.yaml" \
  --wait

echo "Post-check"
istioctl version
istioctl proxy-status
istioctl analyze -A
