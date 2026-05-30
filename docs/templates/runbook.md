# Runbook: {작업명}

> **분류**: {트래픽 전환 | 보안 정책 변경 | 인증서 교체 | 업그레이드}
> **대상 서비스**: {서비스명}
> **작성일**: {YYYY-MM-DD}
> **예상 소요 시간**: {N분}
> **영향 범위**: {무중단 | 순단 N초 | 서비스 중단}

---

## 사전 체크리스트

- [ ] 변경 대상 YAML 백업 완료
- [ ] 관련 팀 슬랙 채널 공지
- [ ] 롤백 YAML 준비 완료
- [ ] Kiali / Prometheus 대시보드 준비

---

## 환경 변수 설정

```bash
export NAMESPACE=<NAMESPACE>
export APP_NAME=<APP_NAME>
export ISTIO_VERSION=1.28.3

# 작업 대상 (시작 전 반드시 확인)
export TARGET_VS=<VIRTUALSERVICE_NAME>
export TARGET_DR=<DESTINATIONRULE_NAME>
```

---

## Step 1: 사전 상태 확인

```bash
# 현재 VirtualService / DestinationRule 상태 백업
kubectl get vs ${TARGET_VS} -n ${NAMESPACE} -o yaml > backup-vs-$(date +%Y%m%d%H%M%S).yaml
kubectl get dr ${TARGET_DR} -n ${NAMESPACE} -o yaml > backup-dr-$(date +%Y%m%d%H%M%S).yaml

# 프록시 동기화 상태 확인
istioctl proxy-status -n ${NAMESPACE}

# 메시 설정 분석
istioctl analyze -n ${NAMESPACE}
```

**예상 출력:**
```
# proxy-status: SYNCED 상태인지 확인
# analyze: No validation issues found
```

---

## Step 2: {작업 내용}

```yaml
# 변경할 YAML
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
...
```

```bash
kubectl apply -f <CHANGE_YAML> -n ${NAMESPACE}
```

**확인 포인트:**
- Envoy 설정이 동기화됐는지 확인 (`istioctl proxy-status`)

---

## Step 3: 완료 확인

```bash
# 변경 후 설정 확인
kubectl get vs -n ${NAMESPACE}
istioctl proxy-config route <POD_NAME> -n ${NAMESPACE}

# 트래픽 정상 흐름 확인 (Kiali 또는 Prometheus)
# istio_requests_total{response_code!~"5.."}
```

**성공 기준:**
- [ ] `istioctl analyze` 에러 없음
- [ ] 에러율 < 1% (5분간 모니터링)
- [ ] P99 응답시간 정상 범위 유지

---

## 롤백 절차

> 아래 상황에서 롤백 수행: {에러율 > 5% / P99 > 1s 지속 / 서비스 불통}

```bash
# 백업 YAML로 롤백
kubectl apply -f backup-vs-<TIMESTAMP>.yaml -n ${NAMESPACE}
kubectl apply -f backup-dr-<TIMESTAMP>.yaml -n ${NAMESPACE}

# 롤백 확인
istioctl analyze -n ${NAMESPACE}
```

---

## 모니터링 포인트

작업 완료 후 **30분간** 아래 지표 모니터링:

| 지표 | 정상 범위 | 이상 기준 |
|------|----------|---------|
| HTTP 에러율 | < 1% | > 5% |
| P99 응답시간 | < 500ms | > 1000ms |
| TCP 연결 에러 | 0 | 지속 발생 |

---

## 완료 보고 템플릿

```
[작업 완료 보고]
- 작업명: {작업명}
- 수행 시간: {시작} ~ {종료}
- 영향: {실제 영향}
- 결과: 정상 완료 / 롤백 / 이슈 발생
- 특이사항: {없음 | 내용}
```
