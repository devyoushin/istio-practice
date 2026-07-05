# Envoy Filter Chain 가이드

> **작성일**: 2026-05-09
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

필터 체인 (Filter Chain)은 Envoy Listener가 트래픽을 수신한 후 적용하는 처리 로직의 순서 목록임. Istio는 EnvoyFilter 리소스를 통해 기본 필터 체인을 커스터마이징할 수 있음.

### 왜 Filter Chain을 이해해야 하는가

- JWT 검증, 헤더 조작, 액세스 로그 커스터마이징 등이 모두 필터 레벨에서 동작함
- EnvoyFilter 오적용 시 전체 트래픽이 차단될 수 있어 구조 이해가 필수

---

## 2. Filter Chain 구조

### 전체 처리 흐름

```
Listener (0.0.0.0:15001)
  │
  ├── Filter Chain Match (TLS SNI, destination IP 등으로 체인 선택)
  │
  └── Filter Chain
        │
        ├── [L4] Network Filters (순서대로 실행)
        │     ├── envoy.filters.network.metadata_exchange
        │     ├── envoy.filters.network.http_connection_manager  ← L7 진입
        │     └── (그 외 TCP 관련 필터)
        │
        └── [L7] HTTP Filters (HCM 내부, 순서대로 실행)
              ├── envoy.filters.http.jwt_authn
              ├── envoy.filters.http.rbac
              ├── envoy.filters.http.fault
              ├── envoy.filters.http.cors
              ├── envoy.filters.http.lua
              └── envoy.filters.http.router  ← 반드시 마지막
```

---

### 주요 Network Filter

| 필터 이름 | 역할 |
|----------|------|
| `envoy.filters.network.http_connection_manager` | HTTP/gRPC 처리 (L7 필터 체인의 시작점) |
| `envoy.filters.network.tcp_proxy` | TCP 레벨 프록시 (L7 처리 불필요 시) |
| `envoy.filters.network.rbac` | TCP 레벨 접근 제어 (IP/포트 기반) |
| `envoy.filters.network.metadata_exchange` | Istio 텔레메트리용 메타데이터 교환 |

---

### 주요 HTTP Filter

| 필터 이름 | Istio 리소스 | 역할 |
|----------|------------|------|
| `envoy.filters.http.jwt_authn` | RequestAuthentication | JWT 토큰 검증 |
| `envoy.filters.http.rbac` | AuthorizationPolicy | HTTP 레벨 접근 제어 |
| `envoy.filters.http.fault` | VirtualService fault | Fault Injection |
| `envoy.filters.http.cors` | VirtualService corsPolicy | CORS 처리 |
| `envoy.filters.http.lua` | EnvoyFilter (직접) | Lua 스크립트 실행 |
| `envoy.filters.http.router` | (내장) | 최종 라우팅 (필수) |

---

### Filter Chain 확인

```bash
# Listener별 Filter Chain 목록
istioctl proxy-config listener <POD_NAME> -n default -o json | \
  jq '.[].filterChains[].filters[].name'

# HTTP Filter 목록 (HCM 내부)
istioctl proxy-config listener <POD_NAME> -n default -o json | \
  jq '.[].filterChains[].filters[] |
      select(.name == "envoy.filters.network.http_connection_manager") |
      .typedConfig.httpFilters[].name'
```

---

## EnvoyFilter로 커스터마이징

### 기본 구조

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: <FILTER_NAME>
  namespace: <NAMESPACE>
spec:
  workloadSelector:
    labels:
      app: <APP_NAME>        # 특정 Pod에만 적용. 생략 시 네임스페이스 전체
  configPatches:
    - applyTo: <TARGET>      # 어디에 적용할지
      match:
        context: <CONTEXT>   # SIDECAR_INBOUND / SIDECAR_OUTBOUND / GATEWAY
        listener:
          filterChain:
            filter:
              name: "envoy.filters.network.http_connection_manager"
      patch:
        operation: <OPERATION>  # INSERT_BEFORE / INSERT_AFTER / MERGE / REPLACE / REMOVE
        value:
          <ENVOY_CONFIG>
```

**applyTo 옵션:**

| 값 | 대상 |
|----|------|
| `LISTENER` | Listener 전체 |
| `FILTER_CHAIN` | Filter Chain |
| `NETWORK_FILTER` | Network Filter |
| `HTTP_FILTER` | HTTP Filter |
| `ROUTE_CONFIGURATION` | Route 설정 |
| `VIRTUAL_HOST` | Virtual Host |

---

### 예시 1: Lua 필터로 요청 헤더 추가

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: add-custom-header
  namespace: default
spec:
  workloadSelector:
    labels:
      app: my-app
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: "envoy.filters.network.http_connection_manager"
              subFilter:
                name: "envoy.filters.http.router"
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.lua
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.LuaPerRoute
          typedConfig:
            "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
            inlineCode: |
              function envoy_on_request(request_handle)
                request_handle:headers():add("x-custom-header", "injected-by-envoy")
              end
```

---

### 예시 2: 특정 경로 접근 차단 (Network Filter RBAC)

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: block-admin-path
  namespace: default
spec:
  workloadSelector:
    labels:
      app: my-app
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: "envoy.filters.network.http_connection_manager"
              subFilter:
                name: "envoy.filters.http.router"
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.rbac
          typedConfig:
            "@type": type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC
            rules:
              action: DENY
              policies:
                block-admin:
                  permissions:
                    - urlPath:
                        path:
                          prefix: /admin
                  principals:
                    - any: true
```

---

### 예시 3: Connection Timeout 변경 (MERGE)

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: adjust-idle-timeout
  namespace: default
spec:
  workloadSelector:
    labels:
      app: my-app
  configPatches:
    - applyTo: NETWORK_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: "envoy.filters.network.http_connection_manager"
      patch:
        operation: MERGE
        value:
          typedConfig:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            stream_idle_timeout: 300s
            request_timeout: 60s
```

---

## 3. 트러블슈팅

### 증상: EnvoyFilter 적용 후 503 에러 급증

#### 원인
`envoy.filters.http.router`가 마지막 위치가 아니거나, 잘못된 `applyTo` / `operation` 조합 사용

#### 해결 방법

```bash
# 1. HTTP Filter 순서 확인 (router가 마지막인지 검증)
istioctl proxy-config listener <POD_NAME> -n default -o json | \
  jq '.[].filterChains[].filters[] |
      select(.name == "envoy.filters.network.http_connection_manager") |
      .typedConfig.httpFilters[].name'

# 2. EnvoyFilter 적용 전/후 비교
# 적용 전: kubectl delete envoyfilter <NAME> -n default
# 적용 후 트래픽 복구되면 EnvoyFilter 설정 오류

# 3. istiod 로그에서 EnvoyFilter 파싱 에러 확인
kubectl logs -n istio-system deployment/istiod | grep -i "envoyfilter\|invalid"

# 4. istioctl analyze로 설정 오류 확인
istioctl analyze -n default
```

---

### 증상: Lua 필터가 동작하지 않음

#### 원인
`inlineCode` 문법 오류 또는 `INSERT_BEFORE`/`INSERT_AFTER` 위치 지정 오류

#### 해결 방법

```bash
# Envoy 로그 레벨을 debug로 변경해 Lua 실행 추적
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST http://localhost:15000/logging?lua=debug

# Lua 에러 로그 확인
kubectl logs <POD_NAME> -n default -c istio-proxy | grep -i lua

# 로그 레벨 원복
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s -X POST http://localhost:15000/logging?lua=warning
```

---

## 4. 모니터링 및 확인

```bash
# 현재 적용된 EnvoyFilter 목록
kubectl get envoyfilter -n default
kubectl get envoyfilter -n istio-system  # 전체 메시에 적용되는 필터

# 특정 Pod의 실제 HTTP Filter 체인 확인
istioctl proxy-config listener <POD_NAME> -n default -o json | \
  jq '[.[].filterChains[].filters[] |
      select(.name == "envoy.filters.network.http_connection_manager") |
      .typedConfig.httpFilters[].name]'

# Envoy 필터 처리 통계 (http.local_rate_limit 등)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "http_filter"
```

---

## 5. TIP

- EnvoyFilter는 강력하지만 Istio 버전 업그레이드 시 내부 필터 이름이 변경될 수 있음. 업그레이드 전 반드시 검증 필요
- `workloadSelector` 없이 `istio-system` 네임스페이스에 배포하면 전체 메시에 적용됨 — 주의
- WASM (WebAssembly) 필터: `envoy.filters.http.wasm` 타입으로 더 복잡한 로직 구현 가능 (별도 빌드 필요)
- `operation: REMOVE`는 Istio 기본 필터도 제거 가능하므로 신중하게 사용
- EnvoyFilter 적용 순서: `istio-system` → 앱 네임스페이스 → workloadSelector 순으로 병합됨
