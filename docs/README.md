# Istio Docs

Istio 학습 문서는 주제별로 나눠 관리합니다.

## 주제 배치 기준

| 폴더 | 역할 | 대표 문서 |
|------|------|-----------|
| `install/` | Istio 설치, 업그레이드, 사이드카 주입, 성능 튜닝 | `install.md`, `istio-upgrade.md`, `mutatingadmissionwebhook-example.md` |
| `traffic-management/` | L7/L4 라우팅, 카나리, 재시도, 장애 주입, 외부 트래픽 제어 | `virtualservice-guide.md`, `destinationrule-guide.md`, `canary-test.md`, `service-entry-guide.md` |
| `security/` | mTLS, AuthorizationPolicy, 인증서 수명주기, 외부 CA, 네임스페이스 분리 | `mtls-guide.md`, `authorization-policy-guide.md`, `mtls-certificate-lifecycle.md` |
| `observability/` | Prometheus, Grafana, Kiali, Jaeger, tracing, 대시보드 | `observability-guide.md`, `prometheus-metrics.md`, `distributed-tracing-guide.md` |
| `envoy/` | Envoy 아키텍처, xDS, filter chain, admin/debug, 지연 진단 | `envoy-architecture.md`, `xds-protocol.md`, `envoy-debug-guide.md` |
| `agents/` | Claude 전문 에이전트 프롬프트 | `doc-writer.md`, `traffic-analyzer.md`, `security-reviewer.md` |
| `rules/` | 문서 작성 규칙, 운영 규칙, 보안 체크리스트 | `doc-writing.md`, `istio-conventions.md`, `security-checklist.md` |
| `templates/` | 재사용 문서 템플릿 | `runbook.md`, `incident-report.md`, `service-doc.md` |

## 문서 표준 구성

일반 가이드 문서는 아래 흐름을 기본으로 작성합니다.

1. `# 문서 제목`
2. 메타 정보: 작성일, Istio 버전, 환경
3. `## 1. 개요`
4. 핵심 설명 또는 동작 원리
5. 설정 예시 또는 실습 절차
6. 모니터링 및 확인
7. 트러블슈팅
8. 참고 링크

## 관리 원칙

- Kubernetes/Istio YAML 예시는 명시적인 `namespace`를 포함합니다.
- Istio networking API 예시는 `networking.istio.io/v1beta1`을 기본으로 사용합니다.
- 실행 자산은 `ops/` 아래에 두고, `docs/`에는 설명과 절차를 둡니다.
- 신규 문서는 `rules/doc-writing.md`와 `rules/istio-conventions.md`를 기준으로 작성합니다.

처음 읽을 문서는 `install/install.md`입니다.
