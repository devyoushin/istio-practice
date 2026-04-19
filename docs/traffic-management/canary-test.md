# Istio Canary 배포 실습

## 디렉토리 구조

```
istio-practice/
├── app/
│   ├── deployment-v1.yaml       # nginx v1 배포
│   ├── deployment-v2.yaml       # nginx v2 배포 (canary)
│   └── service.yaml             # 공통 Service (v1+v2 모두 연결)
├── istio/
│   ├── destination-rule.yaml    # subset(v1, v2) 정의
│   ├── gateway.yaml             # 외부 트래픽 진입점
│   ├── virtual-service-90-10.yaml  # v1:90% / v2:10%
│   ├── virtual-service-50-50.yaml  # v1:50% / v2:50%
│   └── virtual-service-0-100.yaml  # v1:0%  / v2:100%
└── canary-test.md
```

---

## 사전 조건

```bash
# Istio 설치 확인
kubectl get pods -n istio-system

# default 네임스페이스에 사이드카 자동 주입 활성화
kubectl label namespace default istio-injection=enabled

# 확인
kubectl get namespace default --show-labels
```

---

## Step 1: 앱 배포

```bash
# v1, v2 Deployment 배포
kubectl apply -f app/deployment-v1.yaml
kubectl apply -f app/deployment-v2.yaml

# 공통 Service 배포
kubectl apply -f app/service.yaml

# Pod 확인 (READY 2/2 → 사이드카 주입 확인)
kubectl get pods -l app=my-app
```

예상 출력:
```
NAME                         READY   STATUS    RESTARTS
my-app-v1-xxxx               2/2     Running   0
my-app-v1-yyyy               2/2     Running   0
my-app-v2-xxxx               2/2     Running   0
```

> `READY 2/2` 에서 2번째 컨테이너가 Istio 사이드카(Envoy)입니다.

---

## Step 2: DestinationRule 적용

DestinationRule은 Service 뒤의 Pod를 `subset`으로 그룹화합니다.

```bash
kubectl apply -f istio/destination-rule.yaml

# 확인
kubectl get destinationrule
kubectl describe destinationrule my-app
```

**핵심 개념:**
- `subset: v1` → `version: v1` 라벨을 가진 Pod로만 라우팅
- `subset: v2` → `version: v2` 라벨을 가진 Pod로만 라우팅

---

## Step 3: 트래픽 분할 시작 (90% v1 / 10% v2)

```bash
kubectl apply -f istio/virtual-service-90-10.yaml

# 확인
kubectl get virtualservice
kubectl describe virtualservice my-app
```

### 트래픽 테스트

```bash
# 클러스터 내부에서 테스트용 Pod 실행
kubectl run curl-test --image=curlimages/curl -it --rm -- sh

# Pod 안에서 반복 호출
for i in $(seq 1 20); do curl -s http://my-app | grep -o "Version [0-9]"; done
```

예상 결과: 약 18번 "Version 1", 약 2번 "Version 2"

---

## Step 4: 트래픽 증가 (50% v1 / 50% v2)

v2에서 문제가 없으면 트래픽을 늘립니다.

```bash
kubectl apply -f istio/virtual-service-50-50.yaml

# 테스트 (약 50:50으로 분산되는지 확인)
for i in $(seq 1 20); do curl -s http://my-app | grep -o "Version [0-9]"; done
```

---

## Step 5: 완전 전환 (0% v1 / 100% v2)

```bash
kubectl apply -f istio/virtual-service-0-100.yaml

# 전부 v2로 가는지 확인
for i in $(seq 1 10); do curl -s http://my-app | grep -o "Version [0-9]"; done
```

---

## Step 6: v1 제거 (배포 완료)

```bash
kubectl delete deployment my-app-v1
kubectl delete -f istio/virtual-service-0-100.yaml

# DestinationRule에서 v1 subset 제거 (필요 시 수동 편집)
kubectl edit destinationrule my-app
```

---

## 롤백 방법

v2에서 문제가 생기면 즉시 v1으로 되돌립니다.

```bash
kubectl apply -f istio/virtual-service-90-10.yaml  # 또는

# 즉시 전체 롤백
kubectl patch virtualservice my-app --type=json \
  -p='[{"op":"replace","path":"/spec/http/0/route/0/weight","value":100},
       {"op":"replace","path":"/spec/http/0/route/1/weight","value":0}]'
```

---

## 외부 트래픽 (Gateway 사용)

클러스터 외부에서 접근하려면 Gateway를 사용합니다.

```bash
kubectl apply -f istio/gateway.yaml

# Ingress Gateway IP 확인
kubectl get svc istio-ingressgateway -n istio-system

# minikube 사용 시
minikube tunnel  # 별도 터미널에서 실행

# 외부에서 테스트
INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$INGRESS_IP
```

---

## 트래픽 분할 원리

```
클라이언트
   │
   ▼
[Service: my-app]  ← app=my-app 라벨 기준으로 모든 Pod 포함
   │
   ▼ (Envoy 사이드카가 가로챔)
[VirtualService]   ← weight 기준으로 subset에 분배
   ├── 90% → subset: v1 → version=v1 Pod
   └── 10% → subset: v2 → version=v2 Pod
```

**핵심:** Kubernetes Service는 라벨 기반으로 모든 Pod에 균등 분배하지만,
Istio VirtualService + DestinationRule이 그 앞에서 트래픽을 가중치로 제어합니다.

---

## Kiali로 시각화 (선택)

```bash
# Kiali 대시보드 접속
istioctl dashboard kiali

# 또는
kubectl port-forward svc/kiali -n istio-system 20001:20001
# 브라우저에서 http://localhost:20001 접속
```

Graph 탭에서 트래픽 흐름과 비율을 실시간으로 확인할 수 있습니다.

---

## 자주 발생하는 문제

| 증상 | 원인 | 해결 |
|------|------|------|
| READY 1/1 (사이드카 없음) | namespace에 istio-injection 라벨 없음 | `kubectl label namespace default istio-injection=enabled` 후 Pod 재시작 |
| 트래픽이 분할 안 됨 | DestinationRule 없이 VirtualService만 적용 | DestinationRule 먼저 적용 |
| subset not found 에러 | subset 이름 불일치 | DestinationRule의 subset name과 VirtualService의 subset 일치 확인 |
| weight 합계 오류 | weight 합이 100이 아님 | 두 route의 weight 합이 반드시 100이어야 함 |
