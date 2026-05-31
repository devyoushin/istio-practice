#!/usr/bin/env bash
set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.28.3}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-istio-ingress}"

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update istio

kubectl create namespace "${ISTIO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${INGRESS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install istio-base istio/base \
  --namespace "${ISTIO_NAMESPACE}" \
  --version "${ISTIO_VERSION}" \
  --set defaultRevision=default

helm upgrade --install istiod istio/istiod \
  --namespace "${ISTIO_NAMESPACE}" \
  --version "${ISTIO_VERSION}" \
  --values "$(dirname "$0")/istiod-values.yaml" \
  --wait

helm upgrade --install istio-ingress istio/gateway \
  --namespace "${INGRESS_NAMESPACE}" \
  --version "${ISTIO_VERSION}" \
  --values "$(dirname "$0")/ingress-gateway-values.yaml" \
  --wait

istioctl version || true
kubectl get pods -n "${ISTIO_NAMESPACE}"
kubectl get pods -n "${INGRESS_NAMESPACE}"
