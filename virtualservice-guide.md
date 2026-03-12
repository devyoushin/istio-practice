## Istio VirtualService 사양 및 설정 가이드
`VirtualService`는 요청이 서비스에 도달하기 전, 트래픽을 어떻게 라우팅할지 결정하는 규칙을 정의합니다. `DestinationRule`에 정의된 `subset`으로 트래픽을 분류하여 보낼 수 있습니다.

## 1. 주요 라우팅 기능
### 가중치 기반 라우팅 (Weight-based Routing)
트래픽을 퍼센트(%) 단위로 나누어 각 버전(subset)으로 보냅니다. 주로 카나리(Canary) 테스트에 사용됩니다.

### HTTP 매칭 (HTTP Matching)
URI 경로, 헤더, 쿠키 등을 분석하여 특정 버전으로 전달합니다. (예: 특정 사용자 그룹만 v2 접속)

### 재시도 및 타임아웃 (Retries & Timeouts)
요청 실패 시 재시도 횟수나 응답 대기 시간을 설정하여 서비스 안정성을 높입니다.

## 2. 통합 설정 예시 (YAML)
이 설정은 DestinationRule에 v1, v2라는 이름의 subset이 이미 정의되어 있다고 가정하고 작동합니다.
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: my-service-routing
spec:
  hosts:
  - my-service.default.svc.cluster.local
  http:
  # 1. 특정 경로(/api/v2)로 들어오는 요청은 무조건 v2로 전달
  - match:
    - uri:
        prefix: /api/v2
    route:
    - destination:
        host: my-service
        subset: v2

  # 2. 그 외 일반 트래픽은 가중치에 따라 v1과 v2로 분산 (90:10)
  - route:
    - destination:
        host: my-service
        subset: v1
      weight: 90
    - destination:
        host: my-service
        subset: v2
      weight: 10
    
    # 재시도 설정 (오류 발생 시 최대 3번 시도)
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,refused-stream
```

## 3. DestinationRule과의 연결 방식
- Host: 두 리소스 모두 동일한 서비스 도메인(host)을 가리켜야 합니다.
- Subset: VirtualService의 subset 필드 값은 DestinationRule의 subsets.name 필드 값과 반드시 일치해야 합니다.
- 작동 순서:
1. 사용자가 서비스 호출.
2. VirtualService가 경로/가중치를 보고 v1 또는 v2 결정.
3. DestinationRule이 해당 버전 내의 Pod들 중 LEAST_REQUEST 등 설정된 LB 알고리즘으로 최종 Pod 선택.

## 4. 참고 링크
- [공식문서](https://istio.io/latest/docs/reference/config/networking/virtual-service/)
- [crd 참고]()
