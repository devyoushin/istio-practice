# 네트워크 지연 구간별 진단 가이드

> **작성일**: 2026-05-09
> **Istio 버전**: 1.28.3
> **환경**: EKS

---

## 1. 개요

기존 환경에서 지연/타임아웃이 발생하면 tcpdump로 TCP 3-way handshake 타이밍과 RST/FIN 플래그를 확인하는 방식으로 구간을 특정했음. Istio 환경에서는 pod-to-pod 구간이 mTLS로 암호화되어 tcpdump 페이로드 분석이 불가능하며, **Envoy가 TCP 레벨 이벤트를 통계와 응답 플래그로 노출**하므로 이를 활용해 동일한 목적을 달성함.

---

## 2. Istio 환경의 TCP 연결 구조

### 연결 흐름

기존 서비스 간 통신은 TCP 연결 1개지만, Istio에서는 Envoy 사이드카가 개입해 **3개의 TCP 연결**로 분리됨.

```
[Client App]
     │  ① plaintext (localhost)
     ▼
[Client Envoy :15001]  ← iptables REDIRECT
     │
     │  ② mTLS (pod-to-pod, 실제 네트워크 구간)
     ▼
[Server Envoy :15006]  ← iptables REDIRECT
     │  ③ plaintext (localhost)
     ▼
[Server App]
```

| 구간 | 프로토콜 | tcpdump 가능 여부 |
|------|---------|----------------|
| ① Client App → Client Envoy | plaintext | 가능 (localhost 한정) |
| ② Client Envoy → Server Envoy | mTLS (TLS 1.3) | 헤더만 가능, 페이로드 암호화 |
| ③ Server Envoy → Server App | plaintext | 가능 (localhost 한정) |

### 지연이 발생할 수 있는 위치

```
Client App
  │
  │  [A] iptables REDIRECT 오버헤드
  ▼
Client Envoy
  │
  │  [B] 업스트림 연결 수립 (3-way handshake)
  │  [C] mTLS TLS 핸드셰이크
  │  [D] 네트워크 전송 지연 (RTT)
  ▼
Server Envoy
  │
  │  [E] 서버 앱 처리 시간
  ▼
Server App
```

---

## 3. TCP 이벤트 → Envoy 매핑

Envoy는 TCP 레벨 이벤트를 응답 플래그와 통계로 노출함. tcpdump의 TCP 플래그를 보는 대신 아래 매핑을 활용.

### 응답 플래그 (Response Flags)

| TCP 현상 | Envoy 응답 플래그 | 의미 |
|----------|-----------------|------|
| SYN 보냈는데 응답 없음 (handshake timeout) | `UF` | Upstream connection Failure |
| Connection Refused (RST during handshake) | `UF` | 포트 닫혀있거나 Pod 없음 |
| 연결 후 RST 수신 (데이터 전송 중) | `UC` | Upstream Connection termination |
| 업스트림이 FIN/RST 먼저 전송 | `UR` | Upstream Remote reset |
| Connection Pool 한도 초과 (연결 자체 거부) | `UO` | Upstream Overflow |
| 클라이언트가 응답 대기 중 연결 끊음 | `DC` | Downstream Connection termination |
| 요청 처리 시간 초과 | `UT` | Upstream request Timeout |

### Envoy 통계 → TCP 이벤트 매핑

| Envoy 통계 | 대응하는 TCP 이벤트 |
|-----------|-----------------|
| `upstream_cx_connect_fail` | SYN-ACK 미수신 / Connection Refused |
| `upstream_cx_connect_timeout` | 3-way handshake timeout |
| `upstream_cx_connect_ms` | 3-way handshake + TLS handshake 소요 시간 |
| `cx_destroy_remote_with_active_rq` | 요청 처리 중 상대방이 RST/FIN 전송 |
| `cx_destroy_local_with_active_rq` | 요청 처리 중 타임아웃으로 로컬에서 연결 종료 |
| `upstream_cx_overflow` | Connection Pool 한도 초과 |
| `upstream_cx_idle_timeout` | Keep-alive 연결의 idle timeout 만료 |
| `upstream_rq_timeout` | 요청 타임아웃 (HTTP 레벨) |

---

## 4. 구간별 지연 분석

### Access Log로 지연 구간 분리

JSON 포맷 Access Log 기준으로 아래 두 필드를 비교해 지연 위치를 특정함.

```
DURATION                          = 전체 요청 처리 시간 (Client Envoy 기준)
X-ENVOY-UPSTREAM-SERVICE-TIME     = 업스트림 Pod 처리 시간만

네트워크 + Envoy 오버헤드 = DURATION - X-ENVOY-UPSTREAM-SERVICE-TIME
```

**패턴별 해석:**

| duration | upstream_service_time | 지연 위치 추정 |
|----------|-----------------------|--------------|
| 크다 | 크다 | 서버 앱 처리 느림 [E 구간] |
| 크다 | 작다 | 네트워크 또는 Envoy 처리 [B/C/D 구간] |
| 크다 | 없음 (`-`) | 업스트림에 요청 자체가 도달 못함 [A/B 구간] |
| 타임아웃 | 없음 | handshake 실패 또는 연결 수립 불가 [B 구간] |

```bash
# 지연 큰 요청 필터링 (1초 초과)
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  jq 'select(.duration_ms | tonumber > 1000) |
      {path, duration_ms, upstream_service_time_ms, response_flags, upstream_host}'
```

---

### 3-way Handshake 소요 시간 확인

```bash
# 업스트림 연결 수립 시간 통계 (히스토그램)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_cx_connect_ms"

# 예시 출력
# cluster.outbound|8080|v1|my-app.default...upstream_cx_connect_ms: P50=1 P75=2 P95=10 P99=45
# P99가 비정상적으로 크면 네트워크 구간 지연 또는 서버 수용 불가 상태

# 연결 실패 횟수
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "upstream_cx_connect_fail|upstream_cx_connect_timeout"
```

---

### 연결 상태 직접 확인 (ss)

tcpdump 대신 `ss`로 Envoy가 유지하는 TCP 연결 상태를 직접 확인할 수 있음.

```bash
# Envoy 컨테이너 내 TCP 연결 상태 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- ss -tnp

# 예시 출력
# State    Recv-Q  Send-Q  Local Address:Port  Peer Address:Port
# ESTABLISHED 0    0       192.168.1.10:52341  192.168.1.20:8080   (upstream 정상 연결)
# SYN_SENT    0    1       192.168.1.10:52342  192.168.1.21:8080   (handshake 진행 중 / 지연 의심)
# TIME_WAIT   0    0       192.168.1.10:52300  192.168.1.20:8080   (종료된 연결 정리 중)

# SYN_SENT 상태가 다수 있으면 업스트림 연결 지연 또는 Connection Refused 의심
kubectl exec <POD_NAME> -n default -c istio-proxy -- ss -tnp | grep SYN_SENT

# TIME_WAIT 과다 → Keep-alive 설정 부재 또는 짧은 연결 반복
kubectl exec <POD_NAME> -n default -c istio-proxy -- ss -tnp | grep TIME_WAIT | wc -l
```

---

### mTLS TLS Handshake 지연 확인

pod-to-pod 구간의 TLS 핸드셰이크 지연은 인증서 검증 오버헤드로 발생할 수 있음.

```bash
# TLS 핸드셰이크 관련 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep -E "ssl\.(handshake|connection_error|session_reused)"

# ssl.handshake: 총 TLS 핸드셰이크 횟수
# ssl.session_reused: 세션 재사용 횟수 (높을수록 핸드셰이크 오버헤드 감소)
# ssl.connection_error: TLS 핸드셰이크 실패 횟수

# 세션 재사용률 낮으면 → Keep-alive / Connection Pool 설정 검토
```

---

### Connection Pool 상태 확인

연결 부족으로 요청이 큐에 쌓이거나 거부되는 상황 확인.

```bash
# Connection Pool 관련 통계 전체 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "upstream_cx_(active|overflow|total)|upstream_rq_(active|pending|overflow)"

# 주요 지표 해석
# upstream_cx_active:    현재 유지 중인 업스트림 연결 수
# upstream_cx_overflow:  Connection Pool 한도 초과로 거부된 횟수 → UO 플래그 원인
# upstream_rq_pending_overflow: 큐 한도 초과로 거부된 요청 수
# upstream_rq_active:    현재 처리 중인 업스트림 요청 수
```

---

## 5. 시나리오별 진단 흐름

### 시나리오 A: 간헐적 지연 (P99만 높고 P50은 정상)

```bash
# 1. Access Log에서 지연 큰 요청의 upstream_host 확인 (특정 Pod 문제인지)
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  jq 'select(.duration_ms | tonumber > 500) | {upstream_host, duration_ms}'

# 2. 특정 Endpoint만 느리다면 Outlier Detection 고려
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "my-app" | grep -E "cx_connect_ms|rq_time"

# 3. 연결 수립 자체가 느린지 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_cx_connect_ms"

# 4. 특정 Pod가 원인이면 outlierDetection 설정으로 자동 제거
```

```yaml
# outlierDetection 설정 예시
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    outlierDetection:
      consecutiveGatewayErrors: 5   # 5회 연속 에러 시 제거
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

---

### 시나리오 B: 연결 초기에 지연 (첫 요청만 느림)

```bash
# 원인: TLS 핸드셰이크 + TCP handshake 오버헤드 (Connection Pool 미사용)

# 1. 세션 재사용 여부 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "ssl.session_reused"

# 2. 연결 수명 확인 (연결을 너무 자주 새로 맺는지)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "upstream_cx_(total|destroy)" | grep "my-app"
```

```yaml
# 해결: Connection Pool로 연결 재사용 설정
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app-dr
  namespace: default
spec:
  host: my-app
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 3s        # handshake 타임아웃 명시
        tcpKeepalive:
          time: 300s              # idle 연결 유지
          interval: 60s
      http:
        http2MaxRequests: 1000
        maxRequestsPerConnection: 0   # 0 = 연결 무제한 재사용
```

---

### 시나리오 C: 특정 시간대 타임아웃 급증

```bash
# 1. 타임아웃 발생 시점 Access Log 확인 (UT 또는 UF 플래그)
kubectl logs <POD_NAME> -n default -c istio-proxy | \
  grep -E '"response_flags":"U[TF]"' | \
  jq '{timestamp, path, duration_ms, upstream_host, response_flags}'

# 2. 타임아웃 누적 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_rq_timeout"

# 3. 업스트림 연결 자체가 실패하는지 (UF) vs 요청 처리 중 타임아웃 (UT) 구분
# UF: handshake 실패 → 네트워크 또는 업스트림 Pod 문제
# UT: 요청은 갔지만 응답 안 옴 → 서버 처리 지연

# 4. 해당 시간대 업스트림 Pod CPU/Memory 확인
kubectl top pods -n default -l app=my-app
```

---

### 시나리오 D: RST로 연결이 계속 끊김

```bash
# 1. UC (Upstream Connection termination) 플래그 확인
kubectl logs <POD_NAME> -n default -c istio-proxy | grep '"response_flags":"UC"'

# 2. RST 발생 통계
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "cx_destroy_remote_with_active_rq"

# 3. RST 원인 후보
# - 업스트림의 idle timeout이 Envoy Connection Pool의 idle timeout보다 짧음
# - 업스트림 앱이 max request per connection 한도 초과 후 연결 종료
# - 네트워크 장비 (AWS NLB, Security Group)에서 idle timeout으로 RST 전송

# 4. NLB idle timeout (기본 350s) 과 Envoy tcpKeepalive 비교
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "idle_timeout"
```

---

## 6. 트러블슈팅

### 증상: tcpdump를 찍고 싶은데 mTLS 때문에 페이로드가 안 보임

#### 원인
pod-to-pod 구간이 TLS 1.3으로 암호화됨

#### 해결 방법

```bash
# 방법 1: iptables 우회하는 포트에서 plaintext 확인
# 앱 컨테이너의 실제 포트(8080)로 들어오는 트래픽은 plaintext
kubectl exec <POD_NAME> -n default -c <APP_CONTAINER> -- \
  tcpdump -i lo -A port 8080

# 방법 2: TLS 핸드셰이크 패턴만 확인 (페이로드 없이 연결 수립 타이밍)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  tcpdump -i eth0 -nn "tcp[tcpflags] & (tcp-syn|tcp-ack|tcp-fin|tcp-rst) != 0"

# 방법 3: Envoy 통계로 TCP 이벤트 대체 확인 (권장)
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "connect_fail|connect_timeout|destroy_remote|destroy_local"
```

---

### 증상: ss로 SYN_SENT가 다수 보임

#### 원인
업스트림 Pod가 연결을 받지 못하거나 Connection Pool이 소진됨

#### 해결 방법

```bash
# 1. 업스트림 Pod 상태 확인
kubectl get pods -n default -l app=my-app

# 2. 업스트림 Pod의 수신 포트 확인
kubectl exec <SERVER_POD> -n default -c <APP_CONTAINER> -- ss -tlnp

# 3. Envoy Connection Pool 한도 확인
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_cx_overflow"

# 4. 연결 초과라면 DestinationRule maxConnections 상향 조정
```

---

## 7. 모니터링 및 확인

```bash
# 원라이너: 연결/요청 이상 통계 전체 요약
kubectl exec <POD_NAME> -n default -c istio-proxy -- \
  curl -s http://localhost:15000/stats | \
  grep -E "(connect_fail|connect_timeout|cx_overflow|rq_timeout|rq_retry|destroy_remote_with_active|ssl.connection_error)" | \
  grep "my-app"
```

### Prometheus 쿼리

```promql
# 서비스별 P99 요청 지연
histogram_quantile(0.99,
  rate(istio_request_duration_milliseconds_bucket{
    destination_service_name="my-app"
  }[5m])
)

# 연결 실패율
rate(envoy_cluster_upstream_cx_connect_fail{cluster_name=~".*my-app.*"}[5m])

# 타임아웃 발생률
rate(envoy_cluster_upstream_rq_timeout{cluster_name=~".*my-app.*"}[5m])
```

### 진단 치트시트

| 확인 목표 | 명령어 |
|----------|--------|
| 3-way handshake 소요 시간 | `stats \| grep upstream_cx_connect_ms` |
| handshake 실패 횟수 | `stats \| grep upstream_cx_connect_fail` |
| 연결 중 RST 수신 횟수 | `stats \| grep cx_destroy_remote_with_active_rq` |
| Connection Pool 초과 횟수 | `stats \| grep upstream_cx_overflow` |
| TLS 핸드셰이크 실패 | `stats \| grep ssl.connection_error` |
| 세션 재사용률 | `stats \| grep ssl.session_reused` |
| 현재 TCP 연결 상태 | `ss -tnp` |
| 지연 큰 요청 필터 | `access log \| jq 'select(.duration_ms > 1000)'` |

---

## 8. TIP

- `duration - upstream_service_time`이 크면 네트워크/Envoy 구간 문제. `upstream_service_time`이 크면 서버 앱 문제로 책임 구간이 명확히 분리됨
- AWS EKS 환경에서 NLB idle timeout(기본 350s)보다 Envoy의 `tcpKeepalive.time`을 짧게 설정해야 NLB가 끊기 전에 Envoy가 keepalive probe를 보내 RST를 방지할 수 있음
- TIME_WAIT 과다 상태는 Connection Pool(Keep-alive)로 해결 가능. 짧은 연결을 반복하는 패턴은 handshake 오버헤드가 누적되어 P99 지연을 악화시킴
- Envoy 통계는 누적값(counter)이므로 절대값보다 `rate()`로 단위 시간당 변화량으로 판단
