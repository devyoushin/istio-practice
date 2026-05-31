# Helm으로 Istio 설치

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

> [설치 전 참고!! - namespace 분리 이유](../security/namespace-seperation.md)

## 1. 개요

Istio를 Helm chart로 설치하는 기본 절차를 정리함. 설치 대상은 `istio-base`, `istiod`, `istio-ingress`이며, 컨트롤 플레인과 게이트웨이 네임스페이스를 분리하는 구성을 기준으로 함.

## 2. 사전 준비: Helm 저장소 및 네임스페이스

레포지토리 추가 및 업데이트
```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
```

네임스페이스 생성
```bash
kubectl create namespace istio-system
kubectl create namespace istio-ingress
```

## 3. Base (필수 CRD) 설치

```bash
helm install istio-base istio/base -n istio-system --set defaultRevision=default
```

## 4. Istiod (Control Plane) 설치

```bash
helm install istiod istio/istiod -n istio-system --wait
```

## 5. Ingress Gateway 설치

```bash
helm install istio-ingress istio/gateway -n istio-ingress --wait
```

## 6. 설치 확인

```bash
kubectl get pods -n istio-system
kubectl get pods -n istio-ingress
istioctl proxy-status
istioctl analyze -A
```

## 7. 관련 문서

- [Namespace 분리 이유](../security/namespace-seperation.md)
- [Istio 업그레이드](./istio-upgrade.md)
- [사이드카 자동 주입](./mutatingadmissionwebhook-example.md)
