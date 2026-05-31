# Istio DestinationRule 사양 및 설정 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

`DestinationRule`은 가상 서비스(VirtualService) 라우팅이 결정된 후, 실제 엔드포인트에 도달하는 트래픽에 적용될 정책(로드밸런싱, 서킷 브레이커, TLS 등)을 정의합니다.

## 2. 핵심 설정 항목

### 로드밸런싱 (Load Balancing) 

부하 분산 알고리즘을 결정합니다.

- ROUND_ROBIN: 기본값. 순차적 분배.
- LEAST_REQUEST: 활성 요청이 가장 적은 인스턴스 우선.
- RANDOM: 무작위 분배.
- CONSISTENT_HASH: 특정 헤더나 쿠키 기준 세션 유지.

### 서브셋 (Subsets)

라벨을 기반으로 서비스 인스턴스를 논리적으로 그룹화합니다. (예: v1, v2)

### 서킷 브레이커 (Outlier Detection)

비정상적인 엔드포인트를 감지하여 트래픽 대상에서 일시적으로 제외합니다.

## 3. 통합 설정 예시

아래 코드를 복사하여 .yaml 파일로 사용하거나 kubectl apply -f로 실행할 수 있습니다.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-service-destination
  namespace: default
spec:
  host: my-service.default.svc.cluster.local
  trafficPolicy:
    # 전역 로드밸런싱 설정
    loadBalancer:
      simple: LEAST_REQUEST
    
    # 특정 포트에 대한 개별 설정
    portLevelSettings:
    - port:
        number: 8080
      loadBalancer:
        simple: ROUND_ROBIN

    # 커넥션 풀 설정 (Resilience)
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 10
        maxRequestsPerConnection: 1

    # 서킷 브레이커 설정
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50

  # 서비스 버전 분리 (Subsets)
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

## 4. VirtualService와 DestinationRule의 관계

Istio의 트래픽 관리 로직은 크게 **'경로 결정'**과 **'정책 적용'**이라는 두 단계로 나뉩니다.

### 1. 단계별 역할 (Workflow)
#### VirtualService (라우팅 단계)

- 역할: "트래픽이 어디로 가야 하는가?"를 결정합니다.
- 기능: 특정 URL 경로(/api/v1), HTTP 헤더, 혹은 가중치(70% vs 30%)에 따라 트래픽을 분류합니다.
- 연결: 분류된 트래픽을 DestinationRule에서 정의한 subset 이름으로 보냅니다.

#### DestinationRule (정책 단계)

- 역할: "목적지에 도착한 트래픽을 어떻게 처리하는가?"를 결정합니다.
- 기능: 실질적인 Pod 그룹(Subset)을 라벨 기반으로 묶고, 로드밸런싱 알고리즘(Least Request 등)이나 서킷 브레이커를 적용합니다.

## 5. 모니터링 및 확인

```bash
kubectl get destinationrule my-service-destination -n default -o yaml
istioctl analyze -n default
istioctl proxy-config clusters deploy/my-service -n default
```

## 6. 트러블슈팅

| 증상 | 확인 항목 |
|------|-----------|
| subset 라우팅이 실패함 | Pod label과 DestinationRule `subsets.labels` 일치 여부 확인 |
| 로드밸런싱 정책이 보이지 않음 | 대상 워크로드에 Envoy sidecar 주입 여부 확인 |
| 서킷 브레이커가 동작하지 않음 | 실제 5xx 발생 여부와 `outlierDetection` 기준 확인 |

## 7. 참고

- [공식문서](https://istio.io/latest/docs/reference/config/networking/destination-rule/)
- [crd 참고](https://github.com/istio/istio/blob/master/manifests/charts/base/files/crd-all.gen.yaml)
