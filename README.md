# istio-practice

A hands-on repository for learning Istio on EKS.
- **Environment**: EKS / Istio 1.28.3
- **Namespaces**: control plane `istio-system`, app `default`, gateway `istio-ingress`

---

## Learning Path

```
1. Installation    → install.md, install-kiali.md, install-jaeger.md
2. Core Concepts   → virtualservice-guide.md, destinationrule-guide.md
3. Advanced
   ├── Infra         → namespace-seperation.md, mutatingadmissionwebhook-example.md
   ├── Security      → mtls-guide.md, authorization-policy-guide.md
   ├── Resiliency    → fault-injection-guide.md, circuit-breaker-guide.md
   ├── Egress        → service-entry-guide.md, egress-gateway-guide.md
   └── Observability → observability-guide.md
4. Hands-on        → canary-test.md
```

---

## Documents

### Installation
| File | Description |
|------|-------------|
| [install.md](./install.md) | Install Istio (Base, Istiod, Ingress Gateway) via Helm |
| [install-kiali.md](./install-kiali.md) | Install Kiali for traffic visualization |
| [install-jaeger.md](./install-jaeger.md) | Install Jaeger for distributed tracing |

### Core Concepts
| File | Description |
|------|-------------|
| [virtualservice-guide.md](./virtualservice-guide.md) | VirtualService — traffic routing rules (weight, path matching, retries) |
| [destinationrule-guide.md](./destinationrule-guide.md) | DestinationRule — subset definition, load balancing, circuit breaker |

### Advanced
| File | Description |
|------|-------------|
| [namespace-seperation.md](./namespace-seperation.md) | Why istio-system and istio-ingress are separated (security, resource isolation) |
| [mutatingadmissionwebhook-example.md](./mutatingadmissionwebhook-example.md) | How sidecar auto-injection works (MutatingAdmissionWebhook) and troubleshooting |
| [mtls-guide.md](./mtls-guide.md) | mTLS — mutual authentication and encryption between services (PeerAuthentication, STRICT/PERMISSIVE) |
| [authorization-policy-guide.md](./authorization-policy-guide.md) | AuthorizationPolicy — service-to-service RBAC (ALLOW/DENY, Zero Trust pattern) |
| [fault-injection-guide.md](./fault-injection-guide.md) | Fault Injection — simulate failures with intentional delays and errors |
| [circuit-breaker-guide.md](./circuit-breaker-guide.md) | Circuit Breaker — trigger Outlier Detection and verify recovery |
| [service-entry-guide.md](./service-entry-guide.md) | ServiceEntry — register external services (APIs, DBs) into the mesh |
| [egress-gateway-guide.md](./egress-gateway-guide.md) | Egress Gateway — control and audit outbound traffic through a single exit point |
| [observability-guide.md](./observability-guide.md) | Prometheus + Grafana setup, key metrics, and distributed tracing configuration |

### Hands-on
| File | Description |
|------|-------------|
| [canary-test.md](./canary-test.md) | Step-by-step canary deployment (90/10 → 50/50 → 0/100 traffic shift) |

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
