# 장애 보고서: {장애명}

> **발생 시각**: {YYYY-MM-DD HH:MM} KST
> **복구 시각**: {YYYY-MM-DD HH:MM} KST
> **영향 시간**: {N분}
> **심각도**: P1 / P2 / P3
> **영향 범위**: {서비스명, 네임스페이스}

---

## 1. 요약 (Executive Summary)

{3줄 이내로 장애 원인과 조치 내용 요약}

---

## 2. 타임라인

| 시각 | 이벤트 |
|------|--------|
| HH:MM | 최초 알람 발생 |
| HH:MM | 원인 파악 시작 |
| HH:MM | 원인 식별 |
| HH:MM | 조치 시작 |
| HH:MM | 서비스 복구 확인 |
| HH:MM | 모니터링 완료 |

---

## 3. 근본 원인 (Root Cause)

{왜 발생했는지 기술적 원인 설명}

### 관련 Istio 설정

```yaml
# 문제가 된 VirtualService / DestinationRule / AuthorizationPolicy 등
```

### 진단 명령어 실행 결과

```bash
# 장애 시점에 실행한 istioctl / kubectl 출력
istioctl analyze -n <NAMESPACE>
```

---

## 4. 조치 내용

### 즉각 조치 (임시 처리)

```bash
# 롤백 또는 임시 조치 명령어
```

### 영구 조치 (근본 해결)

```yaml
# 수정된 YAML
```

---

## 5. 영향 분석

| 항목 | 내용 |
|------|------|
| 에러율 피크 | {N}% |
| P99 응답시간 피크 | {N}ms |
| 영향받은 서비스 | {서비스 목록} |
| 사용자 영향 | {없음 / 일부 / 전체} |

---

## 6. 재발 방지 대책

| 항목 | 담당 | 기한 |
|------|------|------|
| {예: DestinationRule Circuit Breaker 강화} | {담당자} | {YYYY-MM-DD} |
| {예: AuthorizationPolicy 검토 절차 추가} | {담당자} | {YYYY-MM-DD} |

---

## 7. 참고 자료

- 관련 문서: `docs/{category}/{file}.md`
- 관련 Runbook: `docs/{category}/runbook-{name}.md`
