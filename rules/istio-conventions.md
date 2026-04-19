# Istio 코드 작성 규칙 (Istio Code Conventions)

이 저장소에서 Istio YAML 및 kubectl/istioctl 예시 코드 작성 시 따라야 할 규칙입니다.

---

## 1. YAML 공통 규칙

### 기본 형식
```yaml
apiVersion: networking.istio.io/v1beta1  # v1alpha3 대신 v1beta1 사용
kind: VirtualService
metadata:
  name: <RESOURCE_NAME>
  namespace: <NAMESPACE>               # namespace 항상 명시
spec:
  ...
```

- `apiVersion`은 `v1beta1` 사용 (구버전 `v1alpha3` 지양)
- `namespace` 항상 명시 (default 의존 금지)
- 플레이스홀더: `<NAMESPACE>`, `<SERVICE_NAME>`, `<VERSION>` 형식

### 레이블 필수 항목
```yaml
metadata:
  labels:
    app: <APP_NAME>
    version: <v1|v2>    # 트래픽 분할에 사용되는 핵심 레이블
```

## 2. VirtualService 규칙

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: <SERVICE_NAME>-vs
  namespace: <NAMESPACE>
spec:
  hosts:
    - <SERVICE_NAME>           # 단축 이름 또는 FQDN
  http:
    - name: <ROUTE_NAME>       # 라우트 이름 명시 (디버깅 용이)
      match:
        - headers:
            <HEADER_KEY>:
              exact: <VALUE>
      route:
        - destination:
            host: <SERVICE_NAME>
            subset: <SUBSET_NAME>
          weight: 100
      timeout: 5s              # 타임아웃 항상 명시
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: gateway-error,connect-failure,retriable-4xx
```

## 3. DestinationRule 규칙

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: <SERVICE_NAME>-dr
  namespace: <NAMESPACE>
spec:
  host: <SERVICE_NAME>
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL          # mTLS 항상 명시
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

## 4. AuthorizationPolicy 규칙

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: <POLICY_NAME>
  namespace: <NAMESPACE>
spec:
  selector:
    matchLabels:
      app: <APP_NAME>
  action: ALLOW                 # ALLOW 또는 DENY 명시
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/<SOURCE_NS>/sa/<SERVICE_ACCOUNT>  # 와일드카드 최소화
      to:
        - operation:
            methods: ["GET", "POST"]   # 필요한 메서드만 명시
            ports: ["<PORT>"]
```

## 5. kubectl / istioctl 명령어 규칙

### 기본 형식
```bash
kubectl apply -f <YAML_FILE> -n <NAMESPACE>
kubectl get <RESOURCE> -n <NAMESPACE> -o yaml
istioctl analyze -n <NAMESPACE>
istioctl proxy-status -n <NAMESPACE>
```

- `-n <NAMESPACE>` 항상 명시 (컨텍스트 의존 금지)
- 진단 시 `istioctl analyze` 먼저 실행

## 6. 환경 설정

- 예시의 기본 네임스페이스: `default` (앱), `istio-system` (컨트롤 플레인)
- 앱 이름 컨벤션: `my-app`
- Istio 버전: `1.28.3` (EKS 환경 기준)
