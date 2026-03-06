### 1. 리포지토리 추가 및 업데이트
```bash
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo update
```

### 2. Jaeger 설치
```bash
helm install jaeger jaegertracing/jaeger --namespace istio-system
```
