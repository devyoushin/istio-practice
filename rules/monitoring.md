# 모니터링 작성 기준 (Monitoring Guidelines)

Istio 관련 문서에서 모니터링/확인 섹션 작성 시 따라야 할 기준입니다.

---

## 1. 모니터링 섹션 필수 포함 항목

모든 문서의 **4. 모니터링 및 확인** 섹션에는 아래 중 해당하는 항목을 반드시 포함:

| 항목 | 포함 조건 |
|------|----------|
| `istioctl` 진단 명령어 | 모든 문서 |
| Kiali 확인 경로 | 트래픽 관리 / 관측성 문서 |
| Prometheus 지표명 | 메트릭 관련 문서 |
| Jaeger 트레이싱 확인 | 서비스 간 통신 문서 |
| Envoy Access Log | 트러블슈팅 포함 문서 |

## 2. 핵심 istioctl 진단 명령어

```bash
# 메시 전체 설정 분석 (이슈 자동 감지)
istioctl analyze -n <NAMESPACE>

# 프록시 동기화 상태 확인
istioctl proxy-status -n <NAMESPACE>

# Envoy 설정 상세 확인
istioctl proxy-config cluster <POD_NAME> -n <NAMESPACE>
istioctl proxy-config listener <POD_NAME> -n <NAMESPACE>
istioctl proxy-config route <POD_NAME> -n <NAMESPACE>

# mTLS 상태 확인
istioctl x check-inject -n <NAMESPACE>
```

## 3. 핵심 Prometheus 지표

| 지표 | 설명 | 알람 기준 예시 |
|------|------|--------------|
| `istio_requests_total` | 전체 요청 수 (labels: response_code, source, destination) | 에러율 > 1% |
| `istio_request_duration_milliseconds` | 요청 응답시간 | P99 > 500ms |
| `istio_tcp_connections_opened_total` | TCP 연결 수 | 급격한 증가 |
| `envoy_cluster_upstream_cx_active` | 활성 업스트림 연결 | Circuit Breaker 임계값 근접 |

## 4. Kiali 확인 포인트

- **Graph 뷰**: 서비스 간 트래픽 흐름, 에러율 시각화
- **Workload 뷰**: 개별 Pod Envoy 설정 상태
- **Istio Config 뷰**: VirtualService/DestinationRule 유효성 검사 결과

## 5. Envoy Access Log 형식

```bash
# Access Log에서 에러 필터링
kubectl logs <POD_NAME> -c istio-proxy -n <NAMESPACE> | grep '"response_code":"5'

# 응답 코드별 집계
kubectl logs <POD_NAME> -c istio-proxy -n <NAMESPACE> \
  | python3 -c "import sys,json; [print(json.loads(l).get('response_code','?')) for l in sys.stdin if '{' in l]" \
  | sort | uniq -c | sort -rn
```
