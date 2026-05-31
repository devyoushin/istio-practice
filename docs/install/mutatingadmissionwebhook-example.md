# MutatingAdmissionWebhook 사이드카 주입 가이드

> **작성일**: 2026-05-31
> **Istio 버전**: 1.28.3
> **환경**: EKS

## 1. 개요

Istio는 Kubernetes의 **MutatingAdmissionWebhook**을 사용하여 사이드카(Envoy)를 자동으로 주입합니다. `istioctl experimental check-inject` 명령을 통해 특정 Pod나 네임스페이스의 주입 상태를 점검할 수 있으며, 주입이 실패하거나 비활성화된 경우 관련 Webhook 설정값과 CRD(혹은 리소스 정의)를 확인해야 합니다.

## 2. 설명

### Webhook 설정값 확인 방법

Istio의 사이드카 주입 설정은 `MutatingWebhookConfiguration` 리소스에 저장됩니다. 아래 명령어로 현재 클러스터에 설정된 상세 YAML을 확인할 수 있습니다.


```bash
# 1. 전체 MutatingWebhookConfiguration 리스트 확인
kubectl get mutatingwebhookconfigurations

# 2. 특정 Istio Webhook의 상세 설정(Selector, FailurePolicy 등) 확인
kubectl get mutatingwebhookconfigurations istio-sidecar-injector -o yaml
```

### CRD 및 리소스 정의 (YAML)

실제로 이 Webhook은 Istio 설치 시(Helm 또는 istioctl) 생성되며, 주요 구성 요소는 다음과 같습니다. `objectSelector`나 `namespaceSelector`가 실무에서 가장 빈번하게 체크되는 항목입니다.


```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: istio-sidecar-injector
  labels:
    istio.io/rev: default # 리비전 태그
webhooks:
  - name: rev.namespace.sidecar-injector.istio.io
    clientConfig:
      service:
        name: istiod
        namespace: istio-system
        path: "/inject" # Istiod의 주입 엔드포인트
        port: 443
    rules:
      - operations: ["CREATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
    # [중요] 주입 대상 결정 로직
    namespaceSelector:
      matchExpressions:
        - key: istio-injection
          operator: In
          values: ["enabled"]
    objectSelector:
      matchExpressions:
        - key: sidecar.istio.io/inject
          operator: NotIn
          values: ["false"]
    admissionReviewVersions: ["v1beta1", "v1"]
    sideEffects: None
    failurePolicy: Fail # 웹훅 호출 실패 시 Pod 생성 중단 여부 (Fail/Ignore)
```

## 3. 트러블슈팅

`The injection webhook is deactivated` 메시지 해결

위 로그가 출력되는 이유는 크게 두 가지입니다.

1. **리비전 불일치**: `istio-revision-tag-default`는 활성화되어 있지만, 구형 `istio-sidecar-injector` 웹훅은 관리자에 의해 의도적으로 `reinvocationPolicy`가 꺼져 있거나 조건이 맞지 않게 설정된 경우입니다.
2. **Webhook 비활성화**: YAML 설정 내의 `matchExpressions` 조건이 현재 네임스페이스(`test1`)의 라벨과 일치하지 않을 때 발생합니다.

**해결 단계:**

- 네임스페이스 라벨 확인: `kubectl get ns test1 --show-labels`
- 만약 `istio-injection=enabled` 라벨이 있는데도 안 된다면, 웹훅의 `namespaceSelector`와 `objectSelector`가 서로 충돌하고 있는지 위 YAML 명령어로 확인하세요.

## 4. 참고자료

- [Istio 공식 문서 - Installing Sidecar](https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/)
- [Kubernetes - Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

## 5. 모니터링 및 확인

```bash
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml
istioctl experimental check-inject -n <NAMESPACE> <POD_YAML>
kubectl get pods -n <NAMESPACE> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
```

## 6. TIP

### 실무용 모니터링 및 보안 전략

- **Monitoring**: Webhook 호출 지연이 발생하면 Pod 생성 속도가 급격히 느려집니다. `sidecar_injection_failure_total` 메트릭을 Prometheus에서 모니터링하여 주입 실패율을 체크하세요.
- **Security (FailurePolicy)**: 실무에서는 `failurePolicy: Fail` 설정을 권장합니다. 주입이 실패했는데 Pod가 생성되면(Ignore), 서비스 메시 보안 정책(mTLS)이 적용되지 않은 "naked" Pod가 실행되어 보안 홀이 생길 수 있기 때문입니다.
- **Cost**: 웹훅 자체의 비용보다는, 불필요한 Sidecar 주입으로 인한 리소스 낭비를 막기 위해 `namespaceSelector`를 정교하게 설계하는 것이 중요합니다. (예: `istio-injection=disabled` 명시적 활용)
