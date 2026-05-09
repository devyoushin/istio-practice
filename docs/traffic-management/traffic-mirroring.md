# Traffic Mirroring (Shadowing) 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Traffic Mirroring (트래픽 미러링, 또는 Shadowing)은 운영 트래픽을 실시간으로 복사해 다른 서비스 버전으로 전송하는 기능임. 미러링된 트래픽은 **응답을 클라이언트에 반환하지 않으며** 실제 서비스 응답에 영향을 주지 않음.

### 사용 시점

| 상황 | Mirroring 활용 |
|------|--------------|
| 신규 버전의 실제 트래픽 처리 성능 검증 | v1 응답 유지, v2에 동일 트래픽 복사 |
| 신규 데이터베이스 마이그레이션 검증 | 운영 쿼리를 새 DB에도 전송해 결과 비교 |
| 로그/트레이싱 시스템 교체 검증 | 실제 트래픽으로 신규 시스템 부하 테스트 |
| 카나리 배포 전 안전성 검증 | 가중치 전환 전 미러링으로 문제 사전 발견 |

### Canary 배포와의 차이

| 구분 | Canary 배포 | Traffic Mirroring |
|------|-----------|-----------------|
| 응답 | v2 응답이 클라이언트에 전달 | v2 응답은 버려짐 |
| 장애 영향 | v2 장애가 일부 사용자에게 노출 | v2 장애가 클라이언트에 영향 없음 |
| 사용 목적 | 점진적 트래픽 전환 | 안전한 사전 검증 |

---

## 2. 설정 상세

### 기본 미러링 설정

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app-vs
  namespace: default
spec:
  hosts:
    - my-app
  http:
    - name: main-route
      route:
        - destination:
            host: my-app
            subset: v1
          weight: 100           # 실제 응답은 v1에서
      mirror:
        host: my-app
        subset: v2              # v2로 트래픽 미러링
      mirrorPercentage:
        value: 100.0            # 100%를 미러링 (0.0 ~ 100.0)
```

### 부분 미러링 (운영 트래픽 부하 조절)

```yaml
# 운영 트래픽의 10%만 미러링 (부하 조절)
mirror:
  host: my-app
  subset: v2
mirrorPercentage:
  value: 10.0
```

---

### 미러링 트래픽 특징

미러링된 요청은 `Host` 헤더에 `-shadow` 접미사가 추가됨.

```bash
# 미러링 요청의 Host 헤더
# 원본: Host: my-app
# 미러: Host: my-app-shadow
```

v2 서버의 Access Log에서 미러링 트래픽을 구분하려면 이 헤더를 활용.

```bash
# v2 Pod의 Access Log에서 미러링 트래픽 확인
kubectl logs <V2_POD> -n default -c istio-proxy | grep "my-app-shadow"
```

---

### 미러링과 함께 사용하는 DestinationRule

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

---

### 단계별 활용 패턴

#### 1단계: 미러링으로 v2 검증

```yaml
# v1 100% 처리, v2에 100% 미러링
route:
  - destination:
      host: my-app
      subset: v1
    weight: 100
mirror:
  host: my-app
  subset: v2
mirrorPercentage:
  value: 100.0
```

#### 2단계: 검증 완료 후 Canary 전환

```yaml
# 미러링 제거, v2로 10% 실트래픽 전환
route:
  - destination:
      host: my-app
      subset: v1
    weight: 90
  - destination:
      host: my-app
      subset: v2
    weight: 10
# mirror 필드 삭제
```

---

## 3. 트러블슈팅

### 증상: v2 Pod에 미러링 트래픽이 수신되지 않음

#### 원인
DestinationRule에 v2 subset이 없거나 VirtualService `mirror.subset`이 잘못 지정됨

#### 해결 방법

```bash
# 1. DestinationRule subset 확인
kubectl get destinationrule my-app-dr -n default -o yaml | grep -A 5 "subsets"

# 2. v2 Pod 레이블 확인
kubectl get pods -n default -l version=v2 --show-labels

# 3. v2 Pod Access Log 확인 (미러링 트래픽 수신 여부)
kubectl logs <V2_POD> -n default -c istio-proxy | tail -20

# 4. VirtualService 설정 확인
kubectl get virtualservice my-app-vs -n default -o yaml | grep -A 5 "mirror"

# 5. Istio 구성 분석
istioctl analyze -n default
```

---

### 증상: 미러링 트래픽이 v2 서버에서 에러를 발생시켜 불필요한 알람이 울림

#### 원인
v2 서버의 에러가 Prometheus 메트릭으로 수집되어 알람 트리거

#### 해결 방법

```bash
# v2 Pod의 미러링 트래픽 에러는 클라이언트에 영향 없음을 확인
# 알람 쿼리에서 미러링 대상 subset 제외
```

```promql
# v2(미러링) 제외한 에러율 알람 쿼리
rate(istio_requests_total{
  destination_service_name="my-app",
  destination_version!="v2",    # 미러링 대상 제외
  response_code=~"5.."
}[5m])
```

---

## 4. 모니터링 및 확인

```bash
# VirtualService 미러링 설정 확인
kubectl get virtualservice my-app-vs -n default -o yaml | grep -A 5 "mirror"

# v1 vs v2 요청 수 비교 (미러링이면 거의 동일해야 함)
kubectl exec <CLIENT_POD> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "my-app" | grep "upstream_rq_total"

# v2 Access Log에서 미러링 트래픽 비율 확인
kubectl logs <V2_POD> -n default -c istio-proxy | wc -l
```

### Prometheus 쿼리

```promql
# v1과 v2의 요청 수 비교 (미러링 검증)
sum(rate(istio_requests_total{destination_version="v1",destination_service_name="my-app"}[1m]))
sum(rate(istio_requests_total{destination_version="v2",destination_service_name="my-app"}[1m]))

# v2의 응답 시간 분포 (미러링 중 성능 비교)
histogram_quantile(0.99, rate(istio_request_duration_milliseconds_bucket{
  destination_version="v2",destination_service_name="my-app"
}[5m]))
```

---

## 5. TIP

- 미러링 트래픽은 Envoy가 비동기로 전송하므로 원본 요청 응답 시간에 영향을 주지 않음
- v2에서 데이터베이스에 쓰기 작업이 발생하는 경우 미러링 시 중복 쓰기 발생. 읽기 전용 엔드포인트만 미러링하거나 v2에서 쓰기를 비활성화 처리 필요
- `mirrorPercentage`를 낮게 설정하면 v2의 부하를 조절할 수 있음. v2 스케일이 v1보다 작을 때 유용
- Kiali에서 미러링 트래픽은 점선 화살표로 표시되어 시각적으로 구분 가능
