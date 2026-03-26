# istio-practice

EKS 환경에서 Istio를 학습하기 위한 실습 저장소입니다.
- **환경**: EKS / Istio 1.28.3
- **네임스페이스**: 제어 평면 `istio-system`, 앱 `default`, 게이트웨이 `istio-ingress`

---

## 학습 순서

```
1. 설치           → install.md, install_kiali.md, install_jaeger.md
2. 핵심 개념      → virtualservice-guide.md, destinationrule-guide.md
3. 심화 개념
   ├── 인프라      → namespace_seperation.md, mutatingadmissionwebhook-example.md
   ├── 보안        → mtls-guide.md, authorization-policy-guide.md
   ├── 복원력      → fault-injection-guide.md, circuit-breaker-guide.md
   ├── 트래픽 출구 → service-entry-guide.md, egress-gateway-guide.md
   └── 관찰 가능성 → observability-guide.md
4. 실전 실습      → canary-test.md
```

---

## 문서 목록

### 설치
| 문서 | 내용 |
|------|------|
| [install.md](./install.md) | Helm으로 Istio(Base, Istiod, Ingress Gateway) 설치 |
| [install-kiali.md](./install-kiali.md) | 트래픽 시각화 도구 Kiali 설치 |
| [install-jaeger.md](./install-jaeger.md) | 분산 트레이싱 도구 Jaeger 설치 |

### 핵심 개념
| 문서 | 내용 |
|------|------|
| [virtualservice-guide.md](./virtualservice-guide.md) | VirtualService - 트래픽 라우팅 규칙 정의 (가중치, 경로 매칭, 재시도) |
| [destinationrule-guide.md](./destinationrule-guide.md) | DestinationRule - subset 정의, 로드밸런싱, 서킷 브레이커 |

### 심화 개념
| 문서 | 내용 |
|------|------|
| [namespace-seperation.md](./namespace-seperation.md) | istio-system / istio-ingress 네임스페이스를 분리하는 이유 (보안, 리소스 격리) |
| [mutatingadmissionwebhook-example.md](./mutatingadmissionwebhook-example.md) | 사이드카 자동 주입 원리 (MutatingAdmissionWebhook) 및 트러블슈팅 |
| [mtls-guide.md](./mtls-guide.md) | mTLS - 서비스 간 상호 인증 및 암호화 (PeerAuthentication, STRICT/PERMISSIVE) |
| [authorization-policy-guide.md](./authorization-policy-guide.md) | AuthorizationPolicy - 서비스 간 접근 제어 RBAC (ALLOW/DENY, Zero Trust 패턴) |
| [fault-injection-guide.md](./fault-injection-guide.md) | Fault Injection - 의도적 지연/오류 주입으로 장애 시뮬레이션 |
| [circuit-breaker-guide.md](./circuit-breaker-guide.md) | Circuit Breaker 실습 - Outlier Detection 트리거 및 복구 확인 |
| [service-entry-guide.md](./service-entry-guide.md) | ServiceEntry - 메시 외부 서비스(외부 API, DB) 등록 및 제어 |
| [egress-gateway-guide.md](./egress-gateway-guide.md) | Egress Gateway - 외부 트래픽 단일 출구 제어 및 감사 |
| [observability-guide.md](./observability-guide.md) | Prometheus + Grafana 설치 및 주요 메트릭, 분산 트레이싱 설정 |

### 실전 실습
| 문서 | 내용 |
|------|------|
| [canary-test.md](./canary-test.md) | Canary 배포 단계별 실습 (90/10 → 50/50 → 0/100 트래픽 전환) |

---

## 실습 파일 구조

```
app/
├── deployment-v1.yaml   # 안정 버전 (replicas: 2)
├── deployment-v2.yaml   # 카나리 버전 (replicas: 1)
└── service.yaml         # 공통 Service (v1 + v2 모두 포함)

istio/
├── destination-rule.yaml          # v1, v2 subset 정의
├── gateway.yaml                   # 외부 트래픽 진입점
├── virtual-service-90-10.yaml     # 카나리 시작 (v1: 90%, v2: 10%)
├── virtual-service-50-50.yaml     # 중간 단계 (v1: 50%, v2: 50%)
└── virtual-service-0-100.yaml     # 완전 전환 (v2: 100%)
```

---

## 핵심 개념 요약

**VirtualService + DestinationRule** 조합이 Istio 트래픽 관리의 핵심입니다.

```
클라이언트
    │
    ▼
[VirtualService]  → "어디로 보낼까?" (가중치, 경로, 헤더 기반 라우팅)
    │
    ▼
[DestinationRule] → "어떻게 보낼까?" (subset 그룹화, LB 알고리즘, 서킷 브레이커)
    │
    ▼
  Pod (v1 or v2)
```

> 두 리소스의 `host`와 `subset` 이름이 반드시 일치해야 합니다.
