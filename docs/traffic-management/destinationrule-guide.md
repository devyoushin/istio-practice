## Istio DestinationRule 사양 및 설정 가이드
`DestinationRule`은 가상 서비스(VirtualService) 라우팅이 결정된 후, 실제 엔드포인트에 도달하는 트래픽에 적용될 정책(로드밸런싱, 서킷 브레이커, TLS 등)을 정의합니다.

## 1. 핵심 설정 항목
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

## 2. 통합 설정 예시 (YAML)
아래 코드를 복사하여 .yaml 파일로 사용하거나 kubectl apply -f로 실행할 수 있습니다.
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: my-service-destination
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

## 3. VirtualService와 DestinationRule의 관계
Istio의 트래픽 관리 로직은 크게 **'경로 결정'**과 **'정책 적용'**이라는 두 단계로 나뉩니다.

### 1. 단계별 역할 (Workflow)
#### VirtualService (라우팅 단계)

- 역할: "트래픽이 어디로 가야 하는가?"를 결정합니다.
- 기능: 특정 URL 경로(/api/v1), HTTP 헤더, 혹은 가중치(70% vs 30%)에 따라 트래픽을 분류합니다.
- 연결: 분류된 트래픽을 DestinationRule에서 정의한 subset 이름으로 보냅니다.

#### DestinationRule (정책 단계)

- 역할: "목적지에 도착한 트래픽을 어떻게 처리하는가?"를 결정합니다.
- 기능: 실질적인 Pod 그룹(Subset)을 라벨 기반으로 묶고, 로드밸런싱 알고리즘(Least Request 등)이나 서킷 브레이커를 적용합니다.

## 4. 참고
- [공식문서](https://istio.io/latest/docs/reference/config/networking/destination-rule/)
- [crd 참고](https://github.com/istio/istio/blob/master/manifests/charts/base/files/crd-all.gen.yaml)
