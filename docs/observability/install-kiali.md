### 1. 리포지토리 추가 및 업데이트
```bash
helm repo add kiali https://kiali.org/helm-charts
helm repo update
```

### 2. Kiali Server 설치
```bash
# istio-system 네임스페이스에 설치하는 것이 일반적입니다.
helm install \
  --namespace istio-system \
  --set auth.strategy="anonymous" \
  kiali-server \
  kiali/kiali-server
```
