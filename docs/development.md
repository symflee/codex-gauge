# Codex Gauge 개발 가이드

## 1. 개발 환경

- macOS 13 이상
- Xcode 26.6 stable
- Swift 6 language mode
- Git 2.x
- 선택 사항: GitHub CLI

전체 Xcode를 설치한 뒤 active developer directory를 확인한다.

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
```

Codex Gauge는 외부 Swift package나 런타임을 사용하지 않는다. 새 의존성은 크기, cold start, idle memory, 공급망 위험을 측정한 별도 architecture decision 없이는 추가하지 않는다.

## 2. 빌드와 테스트

전체 Xcode가 없어도 SwiftPM 모듈과 AppKit 개발 호스트를 검증할 수 있다.

```sh
swift package describe
swift build --explicit-target-dependency-import-check error
swift run codex-gauge-tests
swift build -c release --explicit-target-dependency-import-check error
```

shared `CodexGauge` scheme은 실제 `.app` bundle과 UI test의 기준이다. Xcode target은 root package의 `CodexGaugeAppKit` product를 연결하는 얇은 wrapper로 유지한다.

```sh
xcodebuild -project CodexGauge.xcodeproj \
  -scheme CodexGauge \
  -destination 'platform=macOS' \
  test
```

Release build는 서명 없이 로컬에서 검증할 수 있어야 한다.

```sh
xcodebuild -project CodexGauge.xcodeproj \
  -scheme CodexGauge \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

CI와 단위 테스트는 실제 Codex 설치, 사용자 계정과 네트워크에 의존하지 않는다. protocol 테스트는 합성 JSONL fixture와 fake process transport를 사용한다.

## 3. 구현 원칙

- 모든 비-UI 기능은 실패하는 테스트부터 작성하고 최소 구현으로 통과시킨다.
- UI adapter와 quota·refresh 도메인을 분리한다.
- UI 타입과 callback은 `@MainActor` 경계를 명확히 한다.
- main actor에서 blocking process I/O를 실행하지 않는다.
- 함수는 한 가지 역할만 갖도록 작게 유지한다.
- 깊은 중첩보다 guard와 작은 타입·함수로 의도를 표현한다.
- 의미 없는 축약어, forced unwrap과 무분별한 global singleton을 피한다.
- 원문 응답과 민감정보가 assertion failure나 test attachment에 포함되지 않게 한다.
- 기존 동작을 변경하면 같은 task에서 문서와 테스트도 갱신한다.

Java 전용 코딩 규칙은 이 Swift 프로젝트에 적용하지 않는다. Java 소스 도입은 v0.1 범위 밖이며 별도 합의가 필요하다.

## 4. 테스트 전략

### 단위 테스트

저장소의 `codex-gauge-tests` executable은 Apple 테스트 framework가 포함되지 않은 Command Line Tools에서도 실행되는 작은 zero-dependency runner다. 순수 도메인·protocol·refresh 테스트는 이 runner에서 항상 검증한다. 전체 Xcode가 준비되면 UI·performance test에 XCTest를 사용하며, 프레임워크 차이 때문에 TDD를 미루지 않는다.

- remaining percent의 0...100 경계
- duration badge와 unknown duration
- 자동 선택 `5h → w → 최단 양수 → primary/secondary`
- 직접 선택 유지, 누락과 정렬
- Codex·Spark 동일 기간 결합과 다른 기간 frame
- fresh, stale, loading, unavailable 표현
- partial, malformed와 unknown-field protocol fixture
- legacy Codex fallback과 Spark key
- 네 refresh profile과 burst 진입·종료
- reset, 감소와 동일 정수값
- backoff, timeout과 요청 coalescing
- sleep, wake, 잠금과 Low Power Mode
- versioned `UserDefaults` migration
- 최초 실행 상태

### XCTest와 UI 테스트

- fake provider의 `83%` 상태 표시
- 메뉴에서 설정 창 열기
- 최초 실행에 한 번만 설정 창 자동 표시
- 설정 저장 후 닫기·재생성
- 설정 window/controller/view deallocation
- 로그인 시 실행 adapter
- Release CPU와 memory metric

### 로컬 smoke test

실제 App Server smoke test는 명시적인 opt-in 환경에서만 실행한다. 실패 메시지와 attachment에는 raw JSON, 이메일, token, 절대 사용자 경로 또는 실제 quota 값을 남기지 않는다.

## 5. 성능 검증

다음 시나리오를 Release build에서 Instruments의 Time Profiler, Allocations와 Energy Log로 측정한다.

1. 앱 시작 후 10분 idle
2. quota 증가 감지 후 5분 burst
3. 설정 창 열기와 닫기를 10회 반복
4. 여러 표시 frame의 5초 순환
5. sleep/wake와 화면 lock/unlock

Acceptance criteria:

- 기본 자동 선택에서는 rotation timer가 없음
- 균형 프리셋 10분 idle 동안 child 시작 최대 4회
- 조회 사이에 App Server child가 상주하지 않음
- burst당 child 시작 1회
- rotation tick I/O 0회
- 설정 닫기 후 관련 객체 graph 해제
- idle RSS가 빈 AppKit scaffold보다 8MiB 이상 늘지 않음
- 10분 idle 평균 CPU 목표 0.1% 이하

측정 문서에는 hardware class, macOS·Xcode·앱 configuration, 측정 시간, baseline과 결과를 기록한다. 계정 quota 값과 개인 식별 정보는 기록하지 않는다. acceptance criterion을 충족하지 못하면 원인과 후속 task를 함께 남긴다.

## 6. Task와 브랜치

하나의 task는 검증 가능한 결과 하나를 갖는다. 예: quota 계산, JSONL decoder, refresh 상태 머신, status frame, 설정 저장, 로그인 실행.

- bootstrap 이후 main에 직접 커밋하지 않는다.
- GitHub Issue 또는 명시적인 로컬 task마다 짧은 브랜치를 만든다.
- 이름 예: `feat/12-quota-display`, `fix/34-stale-state`, `docs/18-protocol-notes`
- task에 테스트, 구현과 해당 문서 변경을 함께 포함한다.
- 관련 없는 기능이나 대규모 formatting을 섞지 않는다.
- 브랜치 안에서는 red→green 과정의 fixup commit을 허용한다.
- merge 전 전체 테스트를 통과시키고 squash merge한다.
- main에는 task당 green commit 하나만 남긴다.

## 7. Conventional Commits

형식:

```text
<type>(<scope>): <imperative English subject>
```

규칙:

- type과 scope는 소문자
- subject는 영어 명령형, 마침표 없음, 전체 제목 72자 이내
- body에는 구현 나열보다 변경 이유와 사용자 영향을 기록
- 관련 issue는 footer의 `Closes #12`
- breaking change는 `!`와 `BREAKING CHANGE:` 사용
- main에 `WIP`, `fixup`, `temp` 금지

허용 type: `feat`, `fix`, `refactor`, `test`, `docs`, `perf`, `build`, `ci`, `chore`

권장 scope: `repo`, `domain`, `protocol`, `refresh`, `menubar`, `settings`, `launch`, `accessibility`, `macos`, `docs`

예:

```text
chore(repo): bootstrap Codex Gauge
feat(domain): select preferred quota windows
feat(protocol): read Codex rate limits
feat(refresh): add adaptive quota polling
feat(menubar): render quota status frames
```

## 8. 계획된 task 순서

1. repository 문서와 메타데이터
2. AppKit application과 test target scaffold
3. quota domain과 remaining 계산
4. display frame 선택과 순환
5. App Server decoder
6. App Server process session
7. adaptive polling과 system suspension
8. 상태 항목과 상세 메뉴
9. 설정, 진단과 최초 실행
10. 로그인 시 실행과 접근성
11. CI와 universal Release 검증
12. resource baseline과 v0.1 문서 마무리

각 task는 독립적으로 테스트 가능하고 Conventional Commit 하나로 main에 들어가야 한다.

## 9. CI와 공개 배포

- PR에서는 unit/integration test를 필수로 실행한다.
- main 또는 수동 workflow에서 UI smoke와 universal `arm64 x86_64` Release build를 검증한다.
- 공개 CI에서는 `CODE_SIGNING_ALLOWED=NO`를 사용하고 인증서를 요구하지 않는다.
- Actions token은 read-only를 기본값으로 한다.
- main은 force push, branch 삭제와 merge commit을 차단한다.
- 첫 바이너리는 Developer ID 서명과 notarization을 준비한 뒤 공증된 universal ZIP으로만 배포한다.
- 자동 업데이트, DMG와 Homebrew cask는 v0.1 이후 task다.
