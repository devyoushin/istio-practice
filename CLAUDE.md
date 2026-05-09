# CLAUDE.md — istio-practice 지식 베이스

EKS + Istio 운영 경험 기반의 개인 지식 베이스입니다. 문서 추가/수정 시 아래 가이드를 따릅니다.

## 프로젝트 설정

- **환경**: EKS
- **Istio 버전**: 1.28.3
- **Istio 네임스페이스**: `istio-system`
- **Application 네임스페이스**: `default`
- **앱 이름 컨벤션**: `my-app`

---

## 프로젝트 구조

```
istio-practice/
├── docs/                              # 지식 문서 (카테고리별 분류)
│   ├── traffic-management/  (7개)    # VirtualService, DestinationRule, Canary, Circuit Breaker
│   ├── security/            (3개)    # mTLS, AuthorizationPolicy, Namespace 격리
│   ├── observability/       (3개)    # Kiali, Jaeger, Prometheus
│   ├── install/             (2개)    # 설치, MutatingAdmissionWebhook
│   └── envoy/               (5개)    # Envoy 아키텍처, xDS, Filter Chain, Access Log, Admin API, 디버깅
│
├── app/                               # 샘플 앱 Kubernetes 매니페스트
│   ├── deployment-v1.yaml
│   ├── deployment-v2.yaml
│   └── service.yaml
│
├── istio/                             # Istio 리소스 YAML 예제
│   ├── gateway.yaml
│   ├── destination-rule.yaml
│   ├── virtual-service-0-100.yaml
│   ├── virtual-service-50-50.yaml
│   └── virtual-service-90-10.yaml
│
├── templates/                         # 재사용 문서 템플릿
│   ├── service-doc.md                 # 서비스 Istio 구성 문서
│   ├── runbook.md                     # 운영 Runbook
│   └── incident-report.md            # 장애 보고서
│
├── rules/                             # Claude 작성 규칙
│   ├── doc-writing.md                 # 문서 스타일 가이드
│   ├── istio-conventions.md           # YAML/명령어 코드 규칙
│   ├── security-checklist.md          # 보안 검토 체크리스트
│   └── monitoring.md                  # 모니터링/확인 작성 기준
│
├── agents/                            # Claude 전문 에이전트
│   ├── doc-writer.md                  # 문서 작성 에이전트
│   ├── mesh-advisor.md                # 메시 아키텍처 설계/검토 에이전트
│   ├── traffic-analyzer.md            # 트래픽 분석/배포 전략 에이전트
│   └── security-reviewer.md           # 보안 정책 검토 에이전트
│
└── .claude/
    ├── settings.json                  # 프로젝트 공유 설정
    └── commands/                      # 커스텀 슬래시 커맨드
        ├── new-doc.md                 # /new-doc
        ├── new-runbook.md             # /new-runbook
        ├── review-doc.md              # /review-doc
        ├── add-troubleshooting.md     # /add-troubleshooting
        └── search-kb.md               # /search-kb
```

---

## 커스텀 슬래시 커맨드

| 커맨드 | 사용법 | 설명 |
|--------|--------|------|
| `/new-doc` | `/new-doc traffic-management retry-timeout` | 신규 문서 스캐폴딩 |
| `/new-runbook` | `/new-runbook traffic-management canary-rollout` | 운영 Runbook 생성 |
| `/review-doc` | `/review-doc docs/security/mtls-guide.md` | 문서 품질 검토 |
| `/add-troubleshooting` | `/add-troubleshooting docs/traffic-management/circuit-breaker-guide.md <증상>` | 트러블슈팅 추가 |
| `/search-kb` | `/search-kb mTLS STRICT` | 지식 베이스 키워드 검색 |

---

## 파일 네이밍 규칙

```
docs/{카테고리}/{주제}.md
```

- 카테고리: `traffic-management`, `security`, `observability`, `install`
- 주제: 소문자 영어, 하이픈 구분
- 예시: `docs/traffic-management/retry-timeout-guide.md`, `docs/security/jwt-auth-guide.md`

---

## 문서 작성 원칙

1. **실제 경험 기반** — 운영 중 실제로 겪은 이슈와 해결 방법 위주
2. **재현 가능한 코드** — YAML, kubectl/istioctl 명령어 복붙 즉시 적용 가능
3. **원인 중심 트러블슈팅** — 증상만 나열하지 말고 근본 원인 설명
4. **한국어 기술 문서** — 주요 개념은 영어 원문 병기
5. **모니터링 필수** — 모든 문서에 `istioctl` 진단 명령어 포함

세부 규칙은 `rules/` 디렉토리를 참조합니다.

---

## 카테고리별 문서 목록

### docs/traffic-management/
| 파일 | 주제 |
|------|------|
| `virtualservice-guide.md` | VirtualService 라우팅, 가중치 분할, 헤더 기반 라우팅 |
| `destinationrule-guide.md` | DestinationRule subset, 로드밸런싱, Connection Pool |
| `canary-test.md` | Canary 배포 단계별 가중치 전환 실습 |
| `circuit-breaker-guide.md` | Circuit Breaker, outlierDetection, 연결 풀 설정 |
| `fault-injection-guide.md` | Fault Injection (delay/abort), 장애 내성 테스트 |
| `egress-gateway-guide.md` | Egress Gateway로 외부 트래픽 제어 |
| `service-entry-guide.md` | ServiceEntry 외부 서비스 등록, ALLOW_ANY vs REGISTRY_ONLY |

### docs/security/
| 파일 | 주제 |
|------|------|
| `mtls-guide.md` | mTLS STRICT/PERMISSIVE, PeerAuthentication 설정 |
| `mtls-certificate-lifecycle.md` | SPIFFE/SVID 인증서 발급·갱신 원리, SDS, istiod CA 구조 |
| `mtls-migration-guide.md` | PERMISSIVE → STRICT 단계별 마이그레이션 전략 |
| `mtls-debug-guide.md` | mTLS 핸드셰이크 실패 시나리오별 진단 (CONFLICT, 만료, 미주입) |
| `mtls-external-ca.md` | 외부 CA 연동 (플러그인 CA, AWS ACM PCA, Vault, cert-manager) |
| `authorization-policy-guide.md` | AuthorizationPolicy, Default-deny, 최소 권한 |
| `namespace-seperation.md` | 네임스페이스 격리, 멀티 테넌트 메시 구성 |

### docs/observability/
| 파일 | 주제 |
|------|------|
| `observability-guide.md` | Istio 관측성 스택 개요, Prometheus 지표, 트레이싱 |
| `install-kiali.md` | Kiali 설치 및 서비스 그래프 활용 |
| `install-jaeger.md` | Jaeger 설치 및 분산 트레이싱 설정 |

### docs/install/
| 파일 | 주제 |
|------|------|
| `install.md` | Istio EKS 설치, istioctl, Helm 방식 |
| `mutatingadmissionwebhook-example.md` | MutatingAdmissionWebhook 동작 원리, 사이드카 인젝션 |

### docs/envoy/
| 파일 | 주제 |
|------|------|
| `envoy-architecture.md` | Envoy 전체 구조 (Listener → Filter Chain → Cluster → Endpoint), istioctl proxy-config |
| `xds-protocol.md` | xDS API (LDS/RDS/CDS/EDS), istiod → Envoy 설정 전달 흐름, 동기화 확인 |
| `filter-chain-guide.md` | Network/HTTP Filter Chain, EnvoyFilter 커스터마이징 (Lua, RBAC, Timeout) |
| `envoy-access-log.md` | Access Log 포맷, 응답 플래그 해석, JSON 포맷 커스터마이징, Telemetry API |
| `envoy-admin-api.md` | Admin API (15000포트): config_dump, clusters, stats, logging 실전 활용 |
| `envoy-debug-guide.md` | 시나리오별 트러블슈팅 (UH/UF/UO/NR), 진단 흐름, 로그 레벨 디버깅 |
| `network-latency-diagnosis.md` | TCP 구간별 지연 분석, Envoy 통계로 handshake/RST/timeout 진단, ss/tcpdump 활용 |

---

## 추가 예정 주제 (백로그)

- `docs/traffic-management/retry-timeout-guide.md` — Retry/Timeout 실무 권장값
- `docs/security/jwt-auth-guide.md` — RequestAuthentication + JWT 연동
- `docs/observability/prometheus-metrics.md` — Istio Prometheus 지표 상세
- `docs/install/istio-upgrade.md` — Istio 버전 업그레이드 전략
- `docs/traffic-management/traffic-mirroring.md` — Traffic Mirroring(Shadowing) 활용
