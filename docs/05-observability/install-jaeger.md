# Jaeger 설치 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

Jaeger는 Istio 트래픽의 분산 트레이싱(Distributed Tracing)을 확인하기 위한 UI와 collector를 제공함. 이 문서는 Helm 기반 설치만 다루며, 트레이싱 헤더 전파와 샘플링 설정은 별도 가이드에서 다룸.

## 2. 리포지토리 추가 및 업데이트
```bash
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo update
```

## 3. Jaeger 설치
```bash
helm install jaeger jaegertracing/jaeger --namespace istio-system
```

## 4. 설치 확인

```bash
kubectl get pods -n istio-system -l app.kubernetes.io/name=jaeger
kubectl get svc -n istio-system | grep jaeger
```

## 5. 관련 문서

- [분산 트레이싱 심층 가이드](./distributed-tracing-guide.md)
- [관측성 통합 가이드](./observability-guide.md)
