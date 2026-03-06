### 설치 시 참고사항 (Helm 기준)
---
- base: 필수 CRD 설치
- istiod: istio-system 네임스페이스에 설치
- gateway: 별도의 네임스페이스(예: istio-ingress)에 설치

### Namespace 분리 이유
---
#### 1. 보안 및 권한 분리 (RBAC & Blast Radius)
- 가장 큰 이유는 "관리 권한의 최소화" 입니다.
- 공식 문서 취지: istio-system은 서비스 메쉬의 '심장'입니다. 이곳에 대한 수정 권한은 인프라 관리자만 가져야 합니다. 반면, istio-ingress는 트래픽 입구로 설정 변경이 잦을 수 있습니다.
- 폭발 반경(Blast Radius) 제한: 만약 게이트웨이 네임스페이스가 해킹당하거나 설정 실수로 날아가더라도, 별도의 네임스페이스에 있는 istiod(제어 평면)는 안전하게 보호됩니다.


#### 2. 리소스 격리 및 우선순위 (Resource Quota)
- 대규모 환경에서는 특정 컴포넌트가 자원을 독점하는 것을 막아야 합니다.
- ResourceQuota: 네임스페이스별로 CPU와 메모리 사용량을 제한할 수 있습니다. 게이트웨이에 트래픽이 몰려 리소스를 다 써버려도, istio-system에 있는 제어 평면은 미리 할당된 리소스를 바탕으로 안정적으로 가동될 수 있습니다.
- 우선순위(PriorityClass): istiod를 더 높은 우선순위 네임스페이스에 두어, 노드 자원이 부족할 때 게이트웨이보다 제어 평면이 먼저 보호받도록 설정할 수 있습니다.

#### 3. 운영 가시성과 생명주기 관리
- Network Policies: 네임스페이스 단위로 네트워크 정책을 세우기 훨씬 수월합니다. "ingress 네임스페이스는 외부 통신을 허용하지만, system 네임스페이스는 내부망에서만 접근 가능하게 한다" 같은 정책을 적용하기 쉽습니다.
- Istio Revision(Canary Upgrade): Istio를 업그레이드할 때, 네임스페이스가 분리되어 있으면 게이트웨이만 먼저 새 버전으로 올려보거나(Canary), 특정 네임스페이스만 이전 버전을 유지하는 등 생명주기 관리가 매우 유연해집니다.

[참고링크: Installing Gateways](https://istio.io/latest/docs/setup/additional-setup/gateway/)
<img width="2820" height="1584" alt="image" src="https://github.com/user-attachments/assets/b336e62c-4276-4abc-9511-d120dc7d1395" />
