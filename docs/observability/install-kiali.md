# Kiali 설치 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

Kiali는 Istio 서비스 그래프, 트래픽 흐름, mTLS 상태, 설정 검증 결과를 확인하기 위한 운영 UI임. 이 문서는 Helm 기반 설치와 접속 확인 절차를 정리함.

## 2. 리포지토리 추가 및 업데이트
```bash
helm repo add kiali https://kiali.org/helm-charts
helm repo update
```

## 3. Kiali Server 설치
```bash
# istio-system 네임스페이스에 설치하는 것이 일반적입니다.
helm install \
  --namespace istio-system \
  --set auth.strategy="anonymous" \
  kiali-server \
  kiali/kiali-server
```

## 4. 설치 확인

```bash
kubectl get pods -n istio-system -l app.kubernetes.io/name=kiali
istioctl dashboard kiali
```

## 5. 관련 문서

- [관측성 통합 가이드](./observability-guide.md)
- [Grafana 대시보드 가이드](./grafana-dashboard-guide.md)
