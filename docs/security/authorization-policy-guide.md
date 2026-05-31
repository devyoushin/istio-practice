# Istio AuthorizationPolicy 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

**AuthorizationPolicy**는 서비스 간 접근을 제어하는 L4/L7 RBAC입니다.
"어떤 서비스(또는 사용자)가 어떤 서비스의 어떤 경로를 호출할 수 있는가"를 정의합니다.

> mTLS가 "암호화된 통신"이라면, AuthorizationPolicy는 "허가된 통신"입니다. 두 가지를 함께 사용하는 것이 권장됩니다.

---

## 2. 동작 원리

```
서비스 A  →  서비스 B의 Envoy 사이드카
                    │
              AuthorizationPolicy 확인
              ├── ALLOW 조건 충족? → 요청 통과
              ├── DENY 조건 충족?  → 즉시 차단 (ALLOW보다 우선)
              └── 매칭 정책 없음  → 기본 허용 (정책이 하나라도 있으면 기본 거부)
```

---

## 3. 주요 필드

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: example
  namespace: default
spec:
  selector:          # 이 정책을 적용할 대상 Pod
    matchLabels:
      app: my-app
  action: ALLOW      # ALLOW 또는 DENY
  rules:
  - from:            # 요청 출처 조건
    - source:
        principals: ["cluster.local/ns/default/sa/frontend"]
    to:              # 요청 대상 조건
    - operation:
        methods: ["GET"]
        paths: ["/api/*"]
    when:            # 추가 조건 (헤더, JWT 클레임 등)
    - key: request.headers[x-user-role]
      values: ["admin"]
```

---

## 4. 실습 시나리오

### 시나리오: frontend만 my-app의 /api 호출 허용

**1. ServiceAccount 생성**

```bash
kubectl create serviceaccount frontend
kubectl create serviceaccount backend
```

**2. frontend Deployment에 ServiceAccount 지정**

```yaml
spec:
  template:
    spec:
      serviceAccountName: frontend
```

**3. AuthorizationPolicy 적용**

```yaml
# frontend → my-app /api/* 허용
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend-only
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/default/sa/frontend"]
    to:
    - operation:
        methods: ["GET", "POST"]
        paths: ["/api/*"]
```

```bash
kubectl apply -f authorization-policy.yaml
```

**4. 검증**

```bash
# frontend Pod에서 호출 (성공해야 정상)
kubectl exec -it deploy/frontend -- curl http://my-app/api/data

# backend Pod에서 호출 (403 Forbidden이어야 정상)
kubectl exec -it deploy/backend -- curl http://my-app/api/data
```

---

## 5. 전체 차단 후 명시적 허용

모든 트래픽을 기본 차단하고, 필요한 것만 허용하는 방식입니다.

```yaml
# 1. 네임스페이스 전체 차단 (selector 없으면 네임스페이스 전체 적용)
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: default
spec:
  {}   # rules가 없으면 전체 차단
```

```yaml
# 2. 특정 서비스만 허용
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-specific
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["default"]
```

---

## 6. DENY 정책

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-admin-path
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-app
  action: DENY
  rules:
  - to:
    - operation:
        paths: ["/admin/*"]
```

> DENY는 ALLOW보다 우선 적용됩니다. ALLOW 정책이 있어도 DENY 조건에 해당하면 차단됩니다.

---

## 7. 정책 우선순위 정리

```text
DENY 정책 매칭  →  차단 (최우선)
     ↓
ALLOW 정책 매칭  →  허용
     ↓
적용된 ALLOW 정책이 없음 + 정책이 하나라도 존재  →  차단
     ↓
아무 정책도 없음  →  허용 (기본값)
```

---

## 8. 모니터링 및 확인

```bash
kubectl get authorizationpolicy -n default
kubectl describe authorizationpolicy allow-frontend-only

# 특정 Pod에 적용된 정책 확인
istioctl x describe pod <pod-name>
```

---

## 9. 트러블슈팅

| 증상 | 확인 항목 |
|------|-----------|
| 허용 정책 적용 후에도 403 발생 | `principals`, namespace, ServiceAccount 이름 확인 |
| 정책이 너무 넓게 적용됨 | `selector.matchLabels` 누락 여부 확인 |
| DENY가 예상보다 우선 적용됨 | DENY 정책은 ALLOW보다 항상 우선함 |
| 경로 조건이 동작하지 않음 | HTTP 프로토콜 인식 여부와 `paths` 패턴 확인 |

---

## 10. 참고

- [공식문서 - AuthorizationPolicy](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [공식문서 - Authorization 튜토리얼](https://istio.io/latest/docs/tasks/security/authorization/authz-http/)
