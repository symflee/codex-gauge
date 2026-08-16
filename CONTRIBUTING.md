# Codex Gauge에 기여하기

기여에 관심을 가져주셔서 감사합니다. Codex Gauge는 정확한 quota 표현, 낮은 자원 사용과 작은 보안 경계를 최우선으로 합니다.

## 시작하기

1. 관련 issue가 있는지 확인하거나 변경 제안을 issue로 설명합니다.
2. [제품 사양](docs/product-spec.md), [아키텍처](docs/architecture.md), [프로토콜 경계](docs/codex-protocol.md)를 읽습니다.
3. Xcode 26.6과 Swift 6 개발 환경을 준비합니다.
4. main에서 짧은 task branch를 만듭니다.
5. 비-UI 동작은 실패하는 테스트부터 작성합니다.
6. 전체 테스트와 관련 Release build를 통과시킵니다.

## 변경 범위

한 pull request는 검증 가능한 결과 하나만 다룹니다. 테스트, 구현과 그 동작을 설명하는 문서는 같은 pull request에 포함합니다. 관련 없는 refactor, formatting, 의존성 변경을 함께 넣지 마세요.

외부 package 추가, 인증 경계 변경, 새로운 네트워크 endpoint, telemetry 또는 private Codex interface 사용은 먼저 issue에서 architecture·security 영향을 합의해야 합니다.

## 브랜치와 커밋

브랜치 예:

- `feat/12-quota-display`
- `fix/34-stale-state`
- `docs/18-protocol-notes`

Conventional Commit 형식을 사용합니다.

```text
<type>(<scope>): <imperative English subject>
```

예:

```text
feat(protocol): read Codex rate limits
fix(menubar): preserve stale quota state
docs(docs): clarify reset behavior
```

제목은 영어 명령형, 72자 이내, 마침표 없이 작성합니다. pull request는 squash merge하며 PR 제목이 main의 최종 commit 제목이 됩니다. 자세한 규칙은 [개발 가이드](docs/development.md)를 참고하세요.

## 테스트 데이터와 개인정보

- 합성 fixture만 제출합니다.
- 실제 이메일, token, quota 값, reset 시각과 사용자 경로를 commit하지 않습니다.
- `auth.json`, 앱 로그나 실제 App Server 원문을 issue와 PR에 첨부하지 않습니다.
- 오류 재현에는 최소화하고 비식별화한 schema를 사용합니다.

보안 취약점은 공개 issue 대신 [보안 정책](SECURITY.md)의 비공개 절차로 알려주세요.

## Pull request 확인 목록

- [ ] 변경이 하나의 명확한 task에 해당한다.
- [ ] 새 비-UI 동작에 테스트가 있다.
- [ ] 전체 테스트가 통과한다.
- [ ] 관련 문서와 localization resource를 갱신했다.
- [ ] 실제 계정 또는 민감정보가 포함되지 않았다.
- [ ] idle CPU, memory 또는 process lifetime에 영향을 주면 측정 결과를 남겼다.
- [ ] PR 제목이 Conventional Commits 형식이다.

## 행동 기준

상대방을 존중하고 기술적 결정은 재현 가능한 근거, 테스트와 측정으로 논의합니다. 개인정보나 보안상 민감한 내용을 공개 토론에 올리지 않습니다.
