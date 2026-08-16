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

현재 저장소의 source of truth는 root `Package.swift`다. SwiftPM 모듈과 AppKit 개발 호스트를 다음 명령으로 검증한다.

```sh
swift package describe
swift build --explicit-target-dependency-import-check error
swift run codex-gauge-tests
swift build -c release --explicit-target-dependency-import-check error
```

`CodexGauge.xcodeproj`는 `.app` bundle을 위한 얇은 wrapper다. application target은 root package의 `CodexGaugeAppKit` product만 연결하고 `main.swift`, `Info.plist`와 AppIcon을 소유한다. 같은 domain/runtime source를 Xcode target membership에 중복 등록하지 않는다.

```sh
xcodebuild -project CodexGauge.xcodeproj \
  -scheme CodexGauge \
  -destination 'platform=macOS' \
  -only-testing:CodexGaugeUnitTests \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild -project CodexGauge.xcodeproj \
  -scheme CodexGauge \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build
```

shared scheme의 UI smoke는 `CodexGaugeUITests`를 명시해 실행한다. 최초 실행 테스트의 두 launch는 모두 `--codex-gauge-ui-test-fixture-83`으로 외부 경계를 격리하고, 첫 launch에만 `--codex-gauge-ui-test-reset-first-launch`를 더해 완료 flag만 초기화한다. 실제 Codex 설치나 인증을 요구하지 않는다.

package build와 단위 테스트는 실제 Codex 설치, 사용자 계정 또는 애플리케이션 네트워크 요청에 의존하지 않는다. decoder 테스트는 합성 JSONL fixture를 사용한다. process session 통합 테스트는 `codex-gauge-tests` 실행 파일 자체를 test-only 합성 `app-server`로 다시 실행해 handshake, timeout, flood와 종료를 검증한다. production 환경 정책 테스트는 hostile parent PATH가 exact safe PATH로 교체되고 합성 `HOME`·secret 같은 나머지 parent environment가 보존되는지 child 안에서 확인한다. 별도 임시 fixture는 test executable 복사본을 custom interpreter로 사용한 `/usr/bin/env` wrapper로 handshake, account와 rate-limit 조회까지 수행한다. 이 mode는 합성 environment key로만 동작하며 account 이메일이나 원문 사용자 응답을 생성·기록하지 않는다.

CLI version 통합 테스트도 같은 test executable을 `--version`으로 직접 다시 실행한다. 합성 mode는 정상 version, malformed·oversized stdout, nonzero exit, timeout, stderr flood, stdin EOF와 environment 격리를 검증하며 실제 설치 경로, shell, Codex 계정 또는 네트워크를 사용하지 않는다. environment 검증은 App Server와 같은 safe PATH 상수와 별도의 locale allowlist를 사용해 parent의 합성 secret, HOME과 PATH 값이 제거되었는지 child 내부에서 확인한다. 별도 `/tmp` fixture는 현재 test executable을 합성 interpreter로 복사하고 `#!/usr/bin/env <synthetic-name>` wrapper가 주입된 safe search path로 이를 찾는지 검증하므로 Node나 Homebrew 설치에 의존하지 않는다. 즉 인증을 수행하는 App Server child는 PATH 외 environment를 보존하고, 인증이 필요 없는 version child는 allowlist만 전달한다.

refresh executor 단위 테스트는 `RefreshClock`, `RefreshSessionProviding`과 `RefreshUsageSession` fake를 사용한다. 시간 경과는 `ContinuousClock.Instant`를 보존한 가짜 clock의 명시적 `advance`로만 만들며 실제 sleep이나 실제 Codex process를 사용하지 않는다. 비동기 완료 대기는 `Task.yield()`로 actor queue만 비워 wall-clock timing에 의존하지 않는다.

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

저장소의 `codex-gauge-tests` executable은 Apple 테스트 framework가 포함되지 않은 Command Line Tools에서도 실행되는 작은 zero-dependency runner다. 순수 도메인·protocol·refresh 테스트는 이 runner에서 항상 검증한다. Xcode wrapper의 unit·UI target은 XCTest를 사용하며, 프레임워크 차이 때문에 TDD를 미루지 않는다.

- remaining percent의 0...100 경계, 100 미만 소수 사용률의 최소 1%와 100 이상에서만 0% 처리
- duration badge와 unknown duration
- 자동 선택 `5h → w → 최단 양수 → primary/secondary`
- 직접 선택 유지, 누락과 정렬
- Codex·Spark 동일 기간 결합과 다른 기간 frame
- fresh, stale, loading, unavailable 표현
- 상태 접근성 문장의 한국어·영어 localization과 기간 단위 의미 보존
- 기간 배지의 appearance별 재사용과 cache 상한
- 상태 항목이 내부 생성한 `~100%` prototype 기반 고정 폭과 12pt 여백
- 단일 frame의 무-timer 동작과 여러 frame의 5초 순서
- 메뉴 열림, 화면 잠금, sleep, VoiceOver, Reduce Motion 중 순환 중단·재개
- 순환 tick의 사전 렌더 frame 사용과 무-I/O 경계
- 제품별 모든 quota·절대 reset·마지막 성공·typed 오류 menu model
- 제품별 spend-control의 도달 우선순위·남은 비율·불완전 상태 별도 menu 행
- missing·malformed spend-control의 quota 격리와 상태바 frame·순환·폭 입력 불변성
- 메뉴 open/close의 rotation pause와 cached `NSMenu` 무-I/O 경계
- `Codex 열기`·`Codex 선택…` 조건 및 주입 action dispatch
- CLI-only 설치에서 무동작 open 대신 executable 선택 action 제공
- partial, malformed와 unknown-field protocol fixture
- legacy Codex fallback과 Spark key
- 네 refresh profile과 burst 진입·종료
- reset, 감소와 동일 정수값
- backoff, timeout과 요청 coalescing
- 가짜 단조 시계에서 normal poll session 시작·종료와 timer 교체
- burst당 session 하나 재사용, 증가 시 deadline 연장과 실패 시 session 폐기
- terminal failure의 무한 재시도 방지와 수동 복구
- stop 뒤 늦은 completion 폐기, 동시 trigger 병합과 suspend cleanup
- 중복 system resume의 단일 5초 wake-baseline과 Low Power timer clamp
- system suspension·resume 대기 중 quota reset latch와 단일 reset-baseline child
- quota-reset 단발 trigger의 coalescing과 baseline-only 처리
- 제품별 partial window의 fresh publication과 제품별 성공 시각
- 정상 empty quota의 unavailable 전환, malformed empty의 이전 값 stale 보존과 no-prior unavailable
- 정상 empty quota의 accepted 응답 시각과 연결 상태, container 비호환의 terminal 처리
- 합성 App Server를 사용한 smoke locator·provider·session 전체 흐름, shared stop 완료 대기와 categorical 출력
- refresh publication의 상태바 frame·상세 메뉴·discovered quota 단일 투영과 오류 격리
- 제품별 quota reset과 각 cached value의 `capturedAt + 24시간` 중 가장 이른 wall-clock one-shot 예약
- reset·validity typed reason, 지난 deadline 병합과 동일 deadline 중복 방지
- handled identity를 최신 publication 후보로 제한하는 bounded pruning
- snapshot 교체, 시스템 시계 변경, sleep/wake/stop과 늦은 timer generation 폐기
- sleep, wake, 잠금과 Low Power Mode
- sleep·잠금 중첩에서 최초 1회 suspend와 최종 1회 resume
- sleep·잠금별 status rotation pause와 reset-before-resume 직렬 순서
- workspace·power notification의 typed system activity event 변환과 observer 해제
- VoiceOver KVO·accessibility display notification의 최초 상태, 변경 중복 제거와 observer 해제
- versioned `UserDefaults` 기본값, round trip, field 복구와 v0 migration
- manual selection의 표시 제품 교집합 정규화, 빈 교집합 자동 복구와 결정적 encoding
- programmatic 생성·save/load·v0/v1 불일치 payload 정규화와 빈 frame 방어
- file URL 제한과 defaults suite 격리
- 저장 payload에 quota, account, 오류와 원문 응답 field가 없는지 검증
- 로그인 실행 등록·해제의 idempotence, 승인 필요 상태와 typed 오류 축약
- 로그인 실행 actual status의 off·on·mixed UI, unavailable 비활성화와 System Settings recovery
- 시작 reconcile·사용자 요청·앱 재활성화 결과의 열린 설정 live publication과 닫힌 창 재생성
- 앱 재활성화 status가 같으면 typed failure 유지, 바뀌면 obsolete failure 제거
- 저장 intent와 actual status mismatch에서 동일 enable·disable 요청 재시도
- registration·unregistration 실패 문구의 raw `NSError` 비노출과 한국어·영어 key parity
- 설정 form reducer의 제품 filter, 자동·직접 선택과 누락 식별자 유지
- 설정 presenter의 checkbox 활성화와 빈 상태 도출
- 제품 변경 후 off-product 직접 선택 제외와 빈 유효 선택의 자동 복구
- 설정 기간 접근성 문구의 언어별 완전한 단위
- CLI version parser의 두 command prefix, 단일 전체 line, semver-ish component와 4 KiB·64자 상한
- 추가 account·숫자 token, 여러 line, 빈 version component와 잘못된 prefix 거부
- shell 없는 `--version` process의 stdin EOF, locale allowlist·고정 safe PATH와 parent secret 미전달
- `/usr/bin/env` wrapper의 합성 interpreter lookup과 user runtime-manager path 비의존성
- App Server process의 exact safe PATH, hostile parent PATH 교체와 인증용 environment 보존
- custom env interpreter wrapper를 통한 App Server handshake·account·rate-limit 조회
- direct child timeout·cancellation의 stderr 폐기와 TERM/KILL cleanup
- UI의 안전한 basename/category 일반화와 진단 복사의 basename·절대 경로 제거
- refresh publication의 연결 상태 매핑과 sanitized 진단 report
- 초기·실시간 연결 상태의 화면·복사 report 동기화와 in-flight CLI probe의 stale 상태 병합 방지
- 설정 연결 section의 선택·복사 callback과 선택 URL의 원자적 저장
- close/reopen selection generation, commit 이후 callback과 stale task 격리
- `NSOpenPanel` cancellation·늦은 응답 경쟁에서 exactly-once continuation과 새 panel 분리
- pending diagnostics 중 설정 window/controller/view deallocation과 직렬 cleanup
- terminal 설정 shutdown의 pending form save, diagnostics cleanup, panel 취소와 committed selection drain
- form save·repository await 중 shutdown과 terminal 이후 direct show의 nil 반환·무생성
- 설정 표시의 `activate(true) → show → key/front` 순서와 열린 창 재표시당 정확히 한 번의 activation
- window 생성 실패·표시 전 cancellation·shutdown 이후 요청의 무-application-activation 경계
- executable commit 중 close/reopen한 현재 window의 checking 전환과 새 URL diagnostics
- 한국어·영어 비공식·비제휴·experimental App Server 안내 parity
- form 변경의 runtime 적용 callback과 repository 저장 동시 전달
- 초기 조회 뒤 discovery row 갱신의 무저장·무-runtime-callback 동작
- status-first 시작, publication 단일 투영과 저장된 로그인 실행 의도 reconcile
- executable 변경 시 old-stop-before-new-start와 이전 generation publication 폐기
- executable 교체 중 pending 5초 wake phase 보존과 즉시 startup 방지
- validity expiry의 presentation-only 처리와 중복 shutdown의 단일 drain
- 상태 항목 표시와 refresh 시작 이후에만 이루어지는 최초 실행 판단
- visible 설정 창의 한 번만 자동 표시, 표시 전 취소의 미기록과 표시 후 shutdown cancellation의 완료 저장 drain
- 완료된 다음 실행의 자동 표시 생략과 test-only launch argument의 field-only reset
- reset·form·선택 executable·완료 저장이 겹쳐도 sibling preference를 보존하는 actor merge
- pending startup과 경쟁하는 shutdown의 drain 뒤 terminal second-stop
- Quit·Cmd-Q의 terminate-later, runtime 없는 immediate 종료와 exactly-once reply
- UI fixture launch argument의 Debug-only exact match와 first-launch reset 독립 판정
- 저장 설정을 바꾸지 않는 Codex 자동 표시 overlay와 합성 `[5h] 83%` publication
- UI fixture의 무-Codex 탐색·무-process diagnostics·무-`SMAppService` 경계와 terminal stop

### XCTest와 UI 테스트

- fake provider의 `83%` 상태 표시
- 메뉴에서 설정 창 열기
- 최초 실행에 한 번만 설정 창 자동 표시
- 설정 저장 후 닫기·재생성
- 설정 변경 시 숨은 executable URL·최초 실행 field 보존
- 창이 열린 동안 외부에서 바뀐 숨은 field와 form 변경의 원자적 merge
- form·선택 executable·최초 실행 완료의 동시 actor merge와 완료 표시의 멱등성
- 설정 window/controller/view deallocation
- 로그인 시 실행 adapter
- Release CPU와 memory metric

UI 테스트에서 최초 실행 화면을 재현할 때는 정확한 `--codex-gauge-ui-test-reset-first-launch` argument를 사용한다. 이 seam은 namespaced defaults domain을 삭제하지 않고 `hasCompletedFirstLaunch`만 false로 바꾸므로 표시·갱신·로그인·선택 executable 설정을 보존한다. fixture 활성화 자체는 이 flag를 바꾸지 않는다. 일반 production 실행과 smoke test에서는 이 argument를 전달하지 않는다.

상태 항목의 `83%`, 상세 메뉴와 최초 실행 설정 창을 함께 검증하는 XCUITest는 Debug 구성에서 정확한 `--codex-gauge-ui-test-fixture-83` argument를 전달한다. 첫 launch에는 독립된 최초 실행 reset 인자를 함께 전달하고, 후속 launch에는 fixture 인자만 유지해 외부 I/O 없이 한 번만 자동 표시되는 계약을 검증한다. fixture는 실제 AppKit composition 위에 메모리 publication과 무동작 외부 경계를 주입하므로 Codex 설치·로그인·네트워크 또는 로그인 항목 권한이 없어도 결정적으로 실행된다. custom runner는 Debug exact argument 판정, fixture와 reset의 독립성, Release의 강제 production 판정, 저장값의 비변경, 합성 frame, 외부 경계와 shutdown 계약을 검증한다. Release에서는 fixture 타입을 컴파일해 정적 안전성을 확인하지만 인자로 활성화할 수 없다. 이 인자는 production smoke test, 실제 App Server smoke test와 성능 측정에 사용하지 않는다.

### 로컬 App Server smoke

실제 Codex 설치와 로그인 상태를 사용하므로 개발자가 다음 명령을 직접 실행할 때만 동작한다.

```sh
swift run codex-gauge-smoke
```

인자는 지원하지 않는다. 알 수 없는 인자를 전달하면 child를 시작하지 않고 `codex-gauge-smoke: failed reason=invalid_arguments`를 출력한 뒤 종료 코드 64를 반환한다. 일반 `swift build`, `swift run codex-gauge-tests`, Xcode test와 CI workflow는 이 명령을 호출하지 않는다.

성공 출력은 `codex-gauge-smoke: ok codex=<state> spark=<state>` 한 줄이다. 각 제품 state는 다음 네 범주뿐이다.

| state | 의미 |
| --- | --- |
| `available` | 하나 이상의 정상 quota window가 있음 |
| `partial` | 정상 window와 해석 불가 window가 함께 있음 |
| `unavailable` | 현재 제공된 quota window가 없음 |
| `malformed` | 제품 bucket을 안전하게 해석할 수 없음 |

실패 출력은 `codex-gauge-smoke: failed reason=<typed_reason>` 한 줄이다.

| reason | 종료 코드 | 범주 |
| --- | ---: | --- |
| `executable_not_found` | 2 | 실행 파일 탐색 |
| `signed_out`, `unsupported_authentication` | 3 | 인증 상태 |
| `unsupported_version`, `incompatible_protocol`, `protocol_failure` | 4 | protocol 호환성 |
| `timeout`, `process_failure` | 5 | 일시적 transport·process 실패 |
| `cancelled`, `internal_failure` | 6 | 취소 또는 내부 계약 위반 |
| `invalid_arguments` | 64 | 지원하지 않는 CLI 인자 |

`invalid_selection`은 주입 가능한 runner가 selected URL locator와 조합될 때 종료 코드 2로 분류하는 범주다. 현재 no-argument CLI는 앱 설정의 selected URL을 읽지 않으므로 직접 출력하지 않는다.

runner는 locator 검증 로직, production provider와 session을 재사용해 handshake와 한도 조회를 한 번 수행한다. CLI locator에는 selected URL이나 `NSWorkspace` bundle adapter를 주입하지 않으며 알려진 macOS application·Homebrew·local CLI 후보만 검사한다. 성공, 실패와 runner Task cancellation 모두 동일한 shared stop task를 지나며 모든 caller가 child cleanup 완료를 기다린다. 이 Task cancellation 보장은 CLI process signal을 변환하는 기능과 별개다. 출력 formatter는 실제 퍼센트, reset 시각, 이메일, token, account identifier, raw JSONL, stderr, 절대 경로, spend-control과 하위 오류 설명을 입력으로 받지 않는다. 결과를 attachment나 fixture에 기록할 때도 위 categorical 한 줄만 사용한다.

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
11. SwiftPM Debug·test·Release CI
12. Xcode application wrapper, UI test와 universal Release 검증
13. resource baseline과 v0.1 문서 마무리

각 task는 독립적으로 테스트 가능하고 Conventional Commit 하나로 main에 들어가야 한다.

## 9. CI와 공개 배포

- 현재 `.github/workflows/ci.yml`은 pull request, main push와 수동 실행에서 동일한 `build-test` job을 실행한다. branch ruleset의 필수 check 이름도 `build-test`로 고정한다.
- runner는 floating `macos-latest`가 아닌 `macos-26`을 사용하고 `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`로 toolchain을 고정한다.
- gate는 package describe, warnings-as-errors 및 explicit dependency import check를 적용한 SwiftPM Debug build, `swift run codex-gauge-tests`, 동일한 strict Release build와 Xcode unit smoke다. main push와 수동 실행에서는 최초 실행 UI smoke도 수행한다.
- Xcode UI smoke는 별도 인증서나 secret 없이 ad-hoc signing으로 실행한다. Release는 signing을 비활성화하고 exact `arm64 x86_64`로 빌드한 뒤 `lipo`에서 두 architecture와 bundle의 `LSUIElement=true`를 검증한다. ad-hoc test signing과 unsigned build로 배포 서명·공증이나 실제 macOS 13 실행을 대신 주장하지 않는다.
- job timeout은 30분이며 같은 workflow와 ref의 이전 실행은 취소한다.
- workflow `GITHUB_TOKEN`은 `contents: read`만 허용하고 checkout credential을 작업 copy에 유지하지 않는다. checkout 이외의 action, cache, Codecov와 secret을 사용하지 않는다.
- 테스트는 synthetic fixture와 fake 경계만 사용한다. build·test 단계에는 Codex executable, Codex 로그인, OpenAI API key, 사용자 인증 파일 또는 애플리케이션 네트워크 요청이 필요하지 않다.
- `.github/dependabot.yml`은 GitHub Actions reference를 매주 확인한다. action update PR에서는 release tag뿐 아니라 full commit SHA와 version comment가 함께 바뀌었는지 검토한다.
- CI는 `.app` bundle, unit smoke, main의 UI smoke와 universal binary를 검증한다. Instruments resource baseline은 실제 macOS hardware의 opt-in performance gate로 유지한다.
- main은 force push, branch 삭제와 merge commit을 차단한다.
- 첫 바이너리는 Developer ID 서명과 notarization을 준비한 뒤 공증된 universal ZIP으로만 배포한다.
- 자동 업데이트, DMG와 Homebrew cask는 v0.1 이후 task다.
