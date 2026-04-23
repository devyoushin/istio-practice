# istio-practice

A hands-on repository for learning Istio on EKS.
- **Environment**: EKS / Istio 1.28.3
- **Namespaces**: control plane `istio-system`, app `default`, gateway `istio-ingress`

---

## Learning Path

```
1. Installation    → docs/install/
2. Core Concepts   → docs/traffic-management/
3. Advanced
   ├── Security      → docs/security/
   ├── Resiliency    → docs/traffic-management/
   ├── Egress        → docs/traffic-management/
   └── Observability → docs/observability/
4. Hands-on        → docs/traffic-management/canary-test.md
```

---

## Documents

### Installation (`docs/install/`)
| File | Description |
|------|-------------|
| [install.md](./docs/install/install.md) | Install Istio (Base, Istiod, Ingress Gateway) via Helm |
| [mutatingadmissionwebhook-example.md](./docs/install/mutatingadmissionwebhook-example.md) | How sidecar auto-injection works (MutatingAdmissionWebhook) and troubleshooting |

### Traffic Management (`docs/traffic-management/`)
| File | Description |
|------|-------------|
| [virtualservice-guide.md](./docs/traffic-management/virtualservice-guide.md) | VirtualService — traffic routing rules (weight, path matching, retries) |
| [destinationrule-guide.md](./docs/traffic-management/destinationrule-guide.md) | DestinationRule — subset definition, load balancing, circuit breaker |
| [canary-test.md](./docs/traffic-management/canary-test.md) | Step-by-step canary deployment (90/10 → 50/50 → 0/100 traffic shift) |
| [circuit-breaker-guide.md](./docs/traffic-management/circuit-breaker-guide.md) | Circuit Breaker — trigger Outlier Detection and verify recovery |
| [fault-injection-guide.md](./docs/traffic-management/fault-injection-guide.md) | Fault Injection — simulate failures with intentional delays and errors |
| [egress-gateway-guide.md](./docs/traffic-management/egress-gateway-guide.md) | Egress Gateway — control and audit outbound traffic through a single exit point |
| [service-entry-guide.md](./docs/traffic-management/service-entry-guide.md) | ServiceEntry — register external services (APIs, DBs) into the mesh |

### Security (`docs/security/`)
| File | Description |
|------|-------------|
| [mtls-guide.md](./docs/security/mtls-guide.md) | mTLS — mutual authentication and encryption between services (PeerAuthentication, STRICT/PERMISSIVE) |
| [authorization-policy-guide.md](./docs/security/authorization-policy-guide.md) | AuthorizationPolicy — service-to-service RBAC (ALLOW/DENY, Zero Trust pattern) |
| [namespace-seperation.md](./docs/security/namespace-seperation.md) | Why istio-system and istio-ingress are separated (security, resource isolation) |

### Observability (`docs/observability/`)
| File | Description |
|------|-------------|
| [observability-guide.md](./docs/observability/observability-guide.md) | Prometheus + Grafana setup, key metrics, and distributed tracing configuration |
| [install-kiali.md](./docs/observability/install-kiali.md) | Install Kiali for traffic visualization |
| [install-jaeger.md](./docs/observability/install-jaeger.md) | Install Jaeger for distributed tracing |

---

## Manifest Structure

```
app/
├── deployment-v1.yaml   # stable version (replicas: 2)
├── deployment-v2.yaml   # canary version (replicas: 1)
└── service.yaml         # shared Service (selects both v1 and v2)

istio/
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

> The `host` and `subset` names must match exactly between the two resources.
