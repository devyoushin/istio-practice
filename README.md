# istio-practice

A hands-on knowledge base for running Istio on EKS — built from real operational experience.

- **Environment**: EKS / Istio 1.28.3
- **Namespaces**: control plane `istio-system` · app `default` · gateway `istio-ingress`

---

## 어디서 시작할까

- 문서 지도: `docs/README.md`
- Nginx 관점 비교: `docs/01-foundations/nginx-vs-istio.md`
- 첫 문서: `docs/02-installation/install.md`
- 운영 보조 자료: `ops/README.md`
- AI 작업 지침: `CLAUDE.md`

## 구조

| 경로 | 내용 |
|------|------|
| `docs/` | 개념, 설치, 트래픽 관리, 보안, 관측, Envoy, 표준, 템플릿, AI 지침 |
| `ops/` | 샘플 앱과 Istio 리소스 YAML |
| `CLAUDE.md` | 이 레포에서 Claude가 참고할 작업 지침 |

---

## Table of Contents

- [어디서 시작할까](#어디서-시작할까)
- [구조](#구조)
- [Learning Path](#learning-path)
- [Documents](#documents)
  - [Installation](#-installation-4-docs)
  - [Traffic Management](#-traffic-management-11-docs)
  - [Security](#-security-8-docs)
  - [Observability](#-observability-6-docs)
  - [Envoy Deep Dive](#-envoy-deep-dive-7-docs)
- [상세 구조](#상세-구조)
- [Key Concept Summary](#key-concept-summary)

---

## Learning Path

```
1. Installation      → docs/02-installation/
   ├── Install & upgrade Istio on EKS
   └── Understand sidecar injection internals

2. Core Concepts     → docs/01-foundations/ + docs/03-traffic-management/
   ├── Nginx perspective: how Istio takes over proxy, routing, security, observability
   ├── VirtualService + DestinationRule (routing basics)
   └── Canary deployment hands-on

3. Advanced Topics
   ├── Security      → docs/04-security/      (mTLS, AuthorizationPolicy)
   ├── Resiliency    → docs/03-traffic-management/ (Circuit Breaker, Retry, Rate Limit)
   ├── Egress        → docs/03-traffic-management/ (Egress Gateway, ServiceEntry)
   └── Observability → docs/05-observability/ (Prometheus, Tracing, Grafana)

4. Envoy Deep Dive   → docs/06-envoy-deep-dive/
   ├── Architecture, xDS, Filter Chain
   └── Latency diagnosis, Admin API, Debug

5. Hands-on Lab      → docs/03-traffic-management/canary-test.md
```

---

## Documents

### 🧭 Concepts (1 doc)

> Nginx와 비교해 Istio의 역할, 기능, 성능 비용, 운영 방식을 이해

| File | Description |
|------|-------------|
| [nginx-vs-istio.md](./docs/01-foundations/nginx-vs-istio.md) | Nginx upstream/location/proxy_pass 관점에서 Istio Gateway, VirtualService, DestinationRule, mTLS, observability를 매핑 |

---

### 📦 Installation (4 docs)

> Istio 설치, 업그레이드, 사이드카 주입 원리, 성능 튜닝

| File | Description |
|------|-------------|
| [install.md](./docs/02-installation/install.md) | Install Istio (Base, Istiod, Ingress Gateway) via Helm |
| [mutatingadmissionwebhook-example.md](./docs/02-installation/mutatingadmissionwebhook-example.md) | How sidecar auto-injection works (MutatingAdmissionWebhook) and troubleshooting |
| [istio-upgrade.md](./docs/02-installation/istio-upgrade.md) | Canary and In-place upgrade strategies with rollback procedures |
| [istio-performance-tuning.md](./docs/02-installation/istio-performance-tuning.md) | Sidecar resource tuning, concurrency, Sidecar resource scope, stats filtering |

---

### 🚦 Traffic Management (11 docs)

> 트래픽 라우팅, 복원력, 부하 분산, 속도 제한

#### Basics

| File | Description |
|------|-------------|
| [virtualservice-guide.md](./docs/03-traffic-management/virtualservice-guide.md) | VirtualService — weight, path matching, header-based routing |
| [destinationrule-guide.md](./docs/03-traffic-management/destinationrule-guide.md) | DestinationRule — subset definition, load balancing, circuit breaker |
| [canary-test.md](./docs/03-traffic-management/canary-test.md) | Step-by-step canary deployment (90/10 → 50/50 → 0/100 traffic shift) |
| [egress-gateway-guide.md](./docs/03-traffic-management/egress-gateway-guide.md) | Egress Gateway — control and audit outbound traffic |
| [service-entry-guide.md](./docs/03-traffic-management/service-entry-guide.md) | ServiceEntry — register external services (APIs, DBs) into the mesh |

#### Deep Dive

| File | Description |
|------|-------------|
| [circuit-breaker-guide.md](./docs/03-traffic-management/circuit-breaker-guide.md) | Circuit Breaker — Outlier Detection, connection pool limits |
| [fault-injection-guide.md](./docs/03-traffic-management/fault-injection-guide.md) | Fault Injection — simulate delays and aborts for resilience testing |
| [retry-timeout-guide.md](./docs/03-traffic-management/retry-timeout-guide.md) | Retry & Timeout — retryOn conditions, perTryTimeout, Retry Storm prevention |
| [traffic-mirroring.md](./docs/03-traffic-management/traffic-mirroring.md) | Traffic Mirroring (Shadowing) — safe pre-validation before Canary rollout |
| [load-balancing-deep-dive.md](./docs/03-traffic-management/load-balancing-deep-dive.md) | Load Balancing — LEAST_CONN, CONSISTENT_HASH session affinity, Locality LB |
| [rate-limiting-guide.md](./docs/03-traffic-management/rate-limiting-guide.md) | Rate Limiting — local token bucket, global rate limit service integration |

---

### 🔒 Security (8 docs)

> mTLS, 인증서 관리, 접근 제어, 외부 CA 연동

#### Basics

| File | Description |
|------|-------------|
| [mtls-guide.md](./docs/04-security/mtls-guide.md) | mTLS — PeerAuthentication, STRICT/PERMISSIVE modes |
| [tls-mtls-handshake-flow.md](./docs/04-security/tls-mtls-handshake-flow.md) | TLS/mTLS handshake — TCP 3-way handshake, Gateway termination, 내부 mTLS 재암호화 흐름 |
| [authorization-policy-guide.md](./docs/04-security/authorization-policy-guide.md) | AuthorizationPolicy — service-to-service RBAC (ALLOW/DENY, Zero Trust) |
| [namespace-seperation.md](./docs/04-security/namespace-seperation.md) | Namespace isolation — why istio-system and istio-ingress are separated |

#### Deep Dive

| File | Description |
|------|-------------|
| [mtls-certificate-lifecycle.md](./docs/04-security/mtls-certificate-lifecycle.md) | SPIFFE/SVID certificate issuance and renewal — istiod CA and SDS internals |
| [mtls-migration-guide.md](./docs/04-security/mtls-migration-guide.md) | PERMISSIVE → STRICT migration — step-by-step with rollback procedures |
| [mtls-debug-guide.md](./docs/04-security/mtls-debug-guide.md) | mTLS handshake failure diagnosis — CONFLICT, cert expiry, missing sidecar |
| [mtls-external-ca.md](./docs/04-security/mtls-external-ca.md) | External CA integration — plugin CA, AWS ACM PCA, HashiCorp Vault |

---

### 📊 Observability (6 docs)

> 메트릭 수집, 분산 트레이싱, 대시보드, 알람

#### Basics

| File | Description |
|------|-------------|
| [observability-guide.md](./docs/05-observability/observability-guide.md) | Observability stack overview — Prometheus, Grafana, Jaeger setup |
| [install-kiali.md](./docs/05-observability/install-kiali.md) | Kiali — install and use service graph visualization |
| [install-jaeger.md](./docs/05-observability/install-jaeger.md) | Jaeger — install and configure distributed tracing |

#### Deep Dive

| File | Description |
|------|-------------|
| [prometheus-metrics.md](./docs/05-observability/prometheus-metrics.md) | Istio standard metrics, Envoy raw stats, custom labels, alerting queries |
| [distributed-tracing-guide.md](./docs/05-observability/distributed-tracing-guide.md) | B3/W3C header propagation, sampling config, app-level context forwarding |
| [grafana-dashboard-guide.md](./docs/05-observability/grafana-dashboard-guide.md) | Official dashboards, custom panels, Canary comparison, alert rules |

---

### ⚙️ Envoy Deep Dive (7 docs)

> Envoy 내부 동작, xDS 프로토콜, 네트워크 진단

#### Architecture & Protocol

| File | Description |
|------|-------------|
| [envoy-architecture.md](./docs/06-envoy-deep-dive/envoy-architecture.md) | Listener → Filter Chain → Cluster → Endpoint flow, `istioctl proxy-config` |
| [xds-protocol.md](./docs/06-envoy-deep-dive/xds-protocol.md) | LDS/RDS/CDS/EDS — how istiod pushes config to Envoy sidecars |
| [filter-chain-guide.md](./docs/06-envoy-deep-dive/filter-chain-guide.md) | Network/HTTP filter chains, EnvoyFilter customization (Lua, RBAC, timeout) |

#### Operations & Debugging

| File | Description |
|------|-------------|
| [envoy-access-log.md](./docs/06-envoy-deep-dive/envoy-access-log.md) | Access log format, response flag reference (UH/UF/UO/NR), JSON customization |
| [envoy-admin-api.md](./docs/06-envoy-deep-dive/envoy-admin-api.md) | Admin API (port 15000) — config_dump, clusters, stats, log level tuning |
| [envoy-debug-guide.md](./docs/06-envoy-deep-dive/envoy-debug-guide.md) | Scenario-based sidecar troubleshooting with diagnostic command cheat sheet |
| [network-latency-diagnosis.md](./docs/06-envoy-deep-dive/network-latency-diagnosis.md) | Per-segment latency — TCP handshake, RST, timeout diagnosis via Envoy stats |

---

## 상세 구조

```
ops/app/
├── deployment-v1.yaml   # stable version (replicas: 2)
├── deployment-v2.yaml   # canary version (replicas: 1)
└── service.yaml         # shared Service (selects both v1 and v2)

ops/istio/
├── destination-rule.yaml          # defines v1 and v2 subsets
├── gateway.yaml                   # entry point for external traffic
├── virtual-service-90-10.yaml     # canary start  (v1: 90%, v2: 10%)
├── virtual-service-50-50.yaml     # mid-rollout   (v1: 50%, v2: 50%)
└── virtual-service-0-100.yaml     # full cutover  (v2: 100%)
```

---

## Key Concept Summary

**VirtualService + DestinationRule** is the core of Istio traffic management.

```
Client
  │
  ▼
[VirtualService]   → "Where should this go?" (weight, path, header-based routing)
  │
  ▼
[DestinationRule]  → "How should it get there?" (subset grouping, LB algorithm, circuit breaker)
  │
  ▼
Pod (v1 or v2)
```

**Envoy sidecar** intercepts all traffic transparently via iptables.

```
[App Container]
      │  plaintext (localhost)
      ▼
[Envoy :15001/15006]  ←  istiod pushes config via xDS (LDS/RDS/CDS/EDS)
      │  mTLS (pod-to-pod)
      ▼
[Envoy :15006/15001]
      │  plaintext (localhost)
      ▼
[App Container]
```

> The `host` and `subset` names must match exactly between VirtualService and DestinationRule.
