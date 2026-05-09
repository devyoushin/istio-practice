# 로드밸런싱 심층 가이드

> **작성일**: 2026-05-10
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

Istio는 DestinationRule을 통해 Envoy의 다양한 로드밸런싱 알고리즘을 설정할 수 있음. 기본값인 ROUND_ROBIN 외에도 세션 어피니티 (Session Affinity), 최소 연결 (Least Connection) 등 서비스 특성에 맞는 알고리즘을 선택해야 지연과 부하를 최적화할 수 있음.

---

## 2. 로드밸런싱 알고리즘

### 알고리즘 비교

| 알고리즘 | 설정값 | 특징 | 적합한 서비스 |
|---------|--------|------|-------------|
| Round Robin | `ROUND_ROBIN` | 순서대로 균등 분배 (기본값) | 동질한 처리 시간의 API |
| Least Request | `LEAST_CONN` | 활성 요청 수가 적은 Endpoint 우선 | 처리 시간 편차가 큰 서비스 |
| Random | `RANDOM` | 무작위 선택 | 단순 분산, 헬스체크 미사용 시 |
| Passthrough | `PASSTHROUGH` | Envoy가 선택하지 않고 원래 목적지로 | iptables REDIRECT 우회 |
| Ring Hash | `CONSISTENT_HASH` | 해시 기반 세션 어피니티 | 세션/캐시 유지가 필요한 서비스 |

---

### ROUND_ROBIN (기본값)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
```

---

### LEAST_CONN (최소 연결)

처리 시간 편차가 큰 서비스에서 특정 Pod에 요청이 몰리는 현상을 방지.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    loadBalancer:
      simple: LEAST_CONN
```

```bash
# 각 Endpoint의 활성 요청 수 확인 (LEAST_CONN 동작 검증)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "my-app" | grep "rq_active"
```

---

### CONSISTENT_HASH (세션 어피니티)

동일한 클라이언트의 요청을 항상 같은 Endpoint로 라우팅. 캐시 히트율이 중요하거나 세션 상태를 유지해야 하는 서비스에 사용.

**해시 키 기준 옵션:**

| 옵션 | 설명 | 사용 예 |
|------|------|---------|
| `httpHeaderName` | 특정 HTTP 헤더 값 | 사용자 ID 헤더 |
| `httpCookie` | 쿠키 값 (없으면 자동 생성) | 웹 세션 |
| `useSourceIp` | 클라이언트 IP | IP 기반 고정 |
| `httpQueryParameterName` | 쿼리 파라미터 | 테넌트 ID |

#### 헤더 기반 세션 어피니티

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpHeaderName: "x-user-id"    # 이 헤더 값으로 해시
```

```bash
# 동일 헤더 값으로 요청 시 항상 같은 Pod로 라우팅되는지 확인
for i in {1..5}; do
  kubectl exec <CLIENT_POD> -n default -- \
    curl -s -H "x-user-id: user123" http://my-app:8080/ | grep "hostname"
done
# 모두 동일한 Pod 이름이 나와야 함
```

#### 쿠키 기반 세션 어피니티

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: "session-affinity"   # 쿠키 이름
          ttl: 3600s                 # 쿠키 유효 시간 (없으면 Envoy가 자동 생성)
```

#### IP 기반 세션 어피니티

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    loadBalancer:
      consistentHash:
        useSourceIp: true
```

---

### Subset별 다른 로드밸런싱 알고리즘

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN          # 기본: 모든 subset
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
      trafficPolicy:
        loadBalancer:
          simple: LEAST_CONN       # v2만 LEAST_CONN 적용
```

---

### Locality-aware 로드밸런싱 (Zone 인지)

동일 AZ (Availability Zone) 내 Pod를 우선 사용해 레이턴시와 데이터 전송 비용을 줄임.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    loadBalancer:
      localityLbSetting:
        enabled: true
        distribute:
          - from: "ap-northeast-2/ap-northeast-2a/*"
            to:
              "ap-northeast-2/ap-northeast-2a/*": 80    # 같은 AZ 80%
              "ap-northeast-2/ap-northeast-2b/*": 20    # 다른 AZ 20%
        failover:
          - from: ap-northeast-2
            to: ap-northeast-1                           # 리전 페일오버
```

```bash
# 노드의 topology 레이블 확인 (Locality LB 동작 전제)
kubectl get nodes --show-labels | grep "topology.kubernetes.io/zone"
```

---

## 3. 트러블슈팅

### 증상: CONSISTENT_HASH 설정 후에도 요청이 여러 Pod로 분산됨

#### 원인
해시 키로 사용하는 헤더가 요청에 없거나, Subset이 여러 개인데 VirtualService에서 weight 라우팅을 사용하는 경우

#### 해결 방법

```bash
# 1. 요청에 헤더가 실제로 있는지 확인
kubectl exec <CLIENT_POD> -n default -c istio-proxy -- \
  curl -v -H "x-user-id: user123" http://my-app:8080/ 2>&1 | grep "x-user-id"

# 2. Route에 CONSISTENT_HASH 설정이 반영됐는지 확인
istioctl proxy-config cluster <CLIENT_POD> -n default \
  --fqdn my-app.default.svc.cluster.local -o json | \
  jq '.[].lbPolicy'

# 3. 헤더가 없으면 Envoy는 Random으로 폴백함 — 헤더 주입 필수
```

---

### 증상: Locality LB 설정 후 특정 AZ Pod에만 트래픽 집중

#### 원인
같은 AZ에 Pod가 충분하지 않거나 outlierDetection 없이 locality 설정만 적용

#### 해결 방법

```bash
# Endpoint의 Locality 정보 확인
istioctl proxy-config endpoint <POD_NAME> -n default | grep -E "LOCALITY|ZONE"

# outlierDetection 없이 locality LB 사용하면 불량 Endpoint를 제거 못함
# → outlierDetection 함께 설정 권장
```

```yaml
trafficPolicy:
  loadBalancer:
    localityLbSetting:
      enabled: true
  outlierDetection:                      # locality LB와 함께 필수
    consecutiveGatewayErrors: 5
    interval: 10s
    baseEjectionTime: 30s
```

---

## 4. 모니터링 및 확인

```bash
# 현재 로드밸런싱 설정 확인
istioctl proxy-config cluster <POD_NAME> -n default \
  --fqdn my-app.default.svc.cluster.local -o json | \
  jq '.[].lbPolicy'

# Endpoint별 요청 수 분포 확인 (균등 분배 여부)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | \
  grep "my-app" | grep "rq_total"

# Locality 분포 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "my-app" | grep "region\|zone"
```

---

## 5. TIP

- LEAST_CONN은 처리 시간이 긴 API (ML 추론, 이미지 처리 등)에 특히 효과적. ROUND_ROBIN은 빠른 요청이 느린 Pod에 쌓이는 tail latency 문제를 유발할 수 있음
- CONSISTENT_HASH는 Pod 수가 변동되면 해시 링이 재배치되어 기존 어피니티가 깨질 수 있음. HPA와 함께 사용 시 주의
- EKS에서 Locality LB를 사용하려면 노드에 `topology.kubernetes.io/zone` 레이블이 있어야 함 (EKS는 자동 부여)
- `PASSTHROUGH`는 Envoy가 로드밸런싱하지 않고 원래 목적지(ClusterIP)로 전달. 쿠버네티스 kube-proxy가 로드밸런싱을 담당하게 됨
