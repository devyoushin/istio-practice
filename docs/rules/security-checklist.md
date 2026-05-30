# 보안 체크리스트 (Security Checklist)

Istio 관련 문서 작성 및 YAML 작성 시 보안 검토 기준입니다.

---

## 1. mTLS 체크리스트

- [ ] `PeerAuthentication` 모드가 `STRICT`인지 확인 (`PERMISSIVE`는 운영 환경 금지)
- [ ] `PERMISSIVE` 모드 사용 시 반드시 이유 주석 추가 및 임시 적용 명시
- [ ] 모든 워크로드에 Envoy 사이드카가 인젝션됐는지 확인

```bash
# 사이드카 미인젝션 Pod 확인
kubectl get pods -n <NAMESPACE> -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{"\n"}{end}' | grep -v istio-proxy
```

## 2. AuthorizationPolicy 체크리스트

- [ ] 네임스페이스에 Default-deny 정책이 존재하는지 확인
- [ ] 와일드카드(`*`) 사용 시 반드시 이유 주석 추가
- [ ] `source.principals`에 서비스 어카운트를 명확히 지정 (네임스페이스 수준 선택자 지양)
- [ ] `action: DENY` 정책이 `ALLOW`보다 먼저 평가됨 주의

```yaml
# Default-deny 예시 (반드시 네임스페이스에 적용)
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: <NAMESPACE>
spec: {}  # 빈 spec = 모든 트래픽 차단
```

## 3. YAML 보안 체크리스트

- [ ] 하드코딩된 비밀번호, 토큰, 인증서 내용 없는지 확인
- [ ] Secret은 YAML에 직접 포함하지 않고 `secretRef` 사용
- [ ] `hostNetwork: true` / `privileged: true` Pod 사용 금지
- [ ] `0.0.0.0/0` IP 범위 사용 시 주의 문구 추가

## 4. ServiceEntry 체크리스트

- [ ] `ALLOW_ANY` egress 모드 사용 시 반드시 이유 명시 (운영 환경 지양)
- [ ] 외부 서비스 접근은 ServiceEntry로 명시적으로 정의
- [ ] Egress Gateway를 통해 외부 트래픽 제어 권장

## 5. 문서 내 보안 표현 규칙

- 보안 취약 설정 예시 작성 시 반드시 **주의** 또는 **운영 환경 금지** 표시
- 예시:
  ```yaml
  # ⚠️ 주의: 아래 설정은 개발 환경 전용. 운영 환경에서 사용 금지
  mode: PERMISSIVE
  ```
