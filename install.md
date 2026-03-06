# Helm으로 Istio 설치

[설치 전 참고!! - namespace 분리 이유](./ns_seperation.md) 

### 1. 사전 준비: Helm 저장소 및 네임스페이스
---
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

### 2. Base (필수 CRD) 설치
---
```bash
helm install istio-base istio/base -n istio-system --set defaultRevision=default
```

### 3. Istiod (Control Plane) 설치
---
```bash
helm install istiod istio/istiod -n istio-system --wait
```

### 4. Ingress Gateway 설치
---
```bash
helm install istio-ingress istio/gateway -n istio-ingress --wait
```
