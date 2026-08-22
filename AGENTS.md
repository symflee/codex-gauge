# Codex Gauge 작업 지침

이 파일은 저장소 전체에 적용된다. 작업을 시작하기 전에 `README.md`, `docs/product-spec.md`, `docs/architecture.md`, `docs/codex-protocol.md`, `docs/development.md`를 읽고 현재 task와 관련된 계약을 확인한다.

## 제품 경계

- macOS 13 이상을 지원하는 AppKit-only 메뉴 막대 앱이다.
- Swift 6 language mode를 사용한다.
- 외부 package는 기본적으로 추가하지 않는다. Sparkle 2는 별도 updater task에서 architecture·security 문서, 정확한 version pin과 자원 측정을 함께 갱신할 때만 허용한다.
- SwiftUI, WebView, Electron, Tauri와 telemetry를 추가하지 않는다.
- UI는 한국어 우선으로 작성하되 사용자 문자열을 localization 가능한 resource로 분리한다.
- 서버가 주지 않은 기간 의미를 추측하지 않는다.
- 오류를 `0%`로 표시하지 않는다.
- quota snapshot과 raw App Server 응답을 디스크에 저장하지 않는다.

## 구조

- 데이터 흐름은 `Provider → RefreshCoordinator → UsageSnapshot → DisplayFrame → AppKit`을 유지한다.
- UI가 provider 또는 `Process`를 직접 호출하지 않게 한다.
- protocol wire type이 domain·UI로 새지 않게 adapter에서 변환한다.
- main actor에서 blocking I/O를 실행하지 않는다.
- settings window를 닫으면 controller와 view의 강한 참조를 해제한다.
- rotation tick은 캐시된 title만 교체하고 I/O를 수행하지 않는다.

## 보안

- 인증 파일, token, cookie, 세션 로그, private IPC와 비공개 database를 읽지 않는다.
- raw JSONL, stderr, 이메일, 실제 quota와 절대 사용자 경로를 로그·fixture·문서에 넣지 않는다.
- 진단 정보는 비식별 typed error와 환경 metadata로 제한한다.
- executable은 shell을 거치지 않고 검증된 URL로 직접 실행한다.
- 배포 artifact와 설치 안내는 Gatekeeper 또는 quarantine을 비활성화하거나 제거하지 않는다.
- 보안 경계를 바꿔야 하면 구현 전에 `SECURITY.md`와 architecture 문서를 갱신하고 검토를 요청한다.

## 구현과 테스트

- 비-UI 동작은 TDD로 구현한다. 실패 테스트, 최소 구현, refactor 순서를 지킨다.
- 하나의 함수와 타입이 한 가지 역할을 하도록 작게 유지한다.
- guard와 작은 함수로 중첩을 줄인다.
- forced unwrap, 암묵적 전역 상태와 의미 없는 축약을 피한다.
- 시간, process, filesystem, notification과 power 상태는 주입 가능한 경계로 감싼다.
- protocol test는 synthetic fixture만 사용하고 CI가 실제 Codex나 계정을 요구하지 않게 한다.
- 동작 변경 task에는 테스트와 관련 문서 변경을 함께 포함한다.
- 작업을 넘기기 전에 전체 test suite와 적절한 Release build를 실행한다.

Java 전용 규칙은 Swift 코드에 적용하지 않는다. Java 소스 도입은 현재 범위 밖이며 사용자와의 별도 결정 없이는 추가하지 않는다.

## Git

- 하나의 task는 검증 가능한 결과 하나이며 독립 브랜치에서 작업한다.
- 관련 없는 변경, formatting과 기능을 한 commit에 섞지 않는다.
- main에는 squash된 green commit 하나만 남긴다.
- commit은 `<type>(<scope>): <imperative English subject>` 형식의 Conventional Commits를 사용한다.
- main에 `WIP`, `fixup`, `temp` commit을 남기지 않는다.
- 사용자가 맡기지 않은 remote 생성, push, release, 서명 또는 destructive Git 작업을 수행하지 않는다.

세부 branch, commit과 성능 기준은 `docs/development.md`를 따른다.
