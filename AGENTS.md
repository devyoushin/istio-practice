# AGENTS.md — istio-practice Codex 작업 지침

이 저장소는 Istio 학습/운영 지식 베이스입니다. Codex로 작업할 때도 `CLAUDE.md`와 `docs/rules/`의 규칙을 동일하게 따릅니다.

## 공통 원칙

- 기본 언어는 한국어입니다.
- 설명 문서는 `docs/` 아래에 둡니다.
- 실행 가능한 YAML, Helm values, 스크립트는 `ops/` 아래에 둡니다.
- 기존 구조는 `README.md`, `docs/README.md`, `ops/README.md`를 먼저 확인합니다.
- Istio networking API 예시는 기본적으로 `networking.istio.io/v1beta1`을 사용합니다.
- Kubernetes/Istio 예시는 명시적인 `namespace`를 포함합니다.

## Claude와의 싱크

- Claude 작업 지침은 `CLAUDE.md`를 기준으로 합니다.
- Codex도 문서 스타일과 운영 규칙은 `docs/rules/`를 기준으로 합니다.
- 공통 규칙을 바꿀 때는 `CLAUDE.md`, `AGENTS.md`, `docs/rules/`의 참조가 서로 어긋나지 않게 확인합니다.

## 작업 체크리스트

- 변경 전 `git status --short`로 사용자 변경을 확인합니다.
- 문서 링크 변경 후 상대 링크를 확인합니다.
- YAML과 shell script를 추가하면 문법 검사를 수행합니다.
- 커밋 전 `git diff --check`를 수행합니다.
