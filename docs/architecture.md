# Codex Gauge 아키텍처

## 1. 설계 목표

Codex Gauge는 AppKit 기반의 작은 메뉴 막대 프로세스로 유지한다. UI, quota 도메인, 갱신 정책, 외부 프로세스 통신을 분리해 App Server 변경이나 UI 변경이 서로 전파되지 않게 한다.

핵심 제약:

- Swift 6 language mode, macOS 13 이상
- AppKit-only, 외부 패키지 0개
- `LSUIElement=YES`, Dock 아이콘 없음
- App Sandbox 비활성화, Hardened Runtime 활성화
- bundle identifier `io.github.symflee.codex-gauge`
- 계정 snapshot은 메모리에만 유지
- UI와 상태바 rotation timer는 main actor, polling timer와 blocking I/O는 main actor 밖에서 실행

## 2. 데이터 흐름

```text
Codex executable
      │ JSONL over stdin/stdout
      ▼
CodexUsageProviding / UsageSession
      │ UsageSnapshot or typed failure
      ▼
RefreshCoordinator
      │ RefreshPublication
      ▼
RefreshPresentationAdapter / DisplayFrameBuilder
      │ frames, menu input, discovered quota IDs
      ▼
StatusItemController / menu / settings
```

UI adapter는 provider를 직접 호출하지 않는다. 모든 조회는 `RefreshCoordinator`를 통해 직렬화하고, UI는 이미 해석된 snapshot과 상태만 소비한다.

`RefreshPresentationAdapter`는 coordinator가 발행한 immutable 제품별 결과를 하나의 시각에 맞춰 상태바 frame, 상세 메뉴 input과 설정용 discovered quota ID로 투영한다. 전역 실패는 두 제품에 같은 복구 사유를 적용하되 partial·malformed 같은 제품별 issue와 마지막 성공 시각은 서로 오염시키지 않는다. protocol의 `SpendControlLimit`는 이 adapter 안에서 `도달`, `남은 비율`, `미도달·비율 미상`만 가진 semantic menu value로 변환해 wire type이 AppKit model로 새지 않게 한다. adapter는 AppKit, process, timer와 I/O를 알지 않으며 초기 loading 상태에서 임의의 오류나 quota를 만들지 않는다.

composition은 `NSWorkspace`에서 실제 application bundle을 찾았는지를 boolean capability로 presentation adapter에 전달한다. typed not-found·invalid-selection 오류 또는 열 application 부재는 `Codex 선택…` action을 만들고, bundle을 열 수 있을 때만 `Codex 열기`를 만든다. CLI 조회 성공을 application open 가능 상태로 추측하지 않는다.

SwiftPM은 Core, Protocol, Refresh, Settings와 AppKit 모듈의 단일 source of truth다. Xcode application target은 이 package의 `CodexGaugeAppKit` product와 `App/CodexGauge`의 bundle metadata만 소유한다. 같은 Swift 소스를 package와 Xcode target membership에 중복 등록하지 않는다.

### 런타임 composition

`CodexGaugeApplicationCoordinator`는 앱 수명 동안 하나만 존재하는 `@MainActor` composition root다. 동일한 `SystemStatusItemPresenter`를 사용하는 status controller와 menu controller, lazy settings coordinator, system·assistive monitor, wall-clock deadline scheduler, 로그인 실행 adapter와 현재 refresh coordinator를 소유한다. `CodexGaugeApplicationDelegate`는 이 root를 생성·보유하고 한 번만 시작한다.

시작 순서는 상태 항목의 loading frame과 cached menu 표시, deadline scheduler·monitor 연결, preferences load, provider 구성, refresh 시작 순이다. 따라서 `UserDefaults` actor hop 전에 상태 항목이 먼저 보인다. 저장된 로그인 실행 의도는 refresh 시작 뒤 `SMAppService` 상태와 한 번 reconcile한다. 최초 실행 판단은 refresh coordinator에 `start()`를 전달한 뒤의 startup hook에서만 이어진다.

factory는 launch argument를 시스템 adapter 생성 전에 판정한다. Debug 빌드에서 정확한 `--codex-gauge-ui-test-fixture-83`가 전달된 경우에만 production locator·App Server refresh builder·connection inspector·`NSWorkspace` Codex adapter와 `LaunchAtLoginController`를 생성하지 않는다. 대신 terminal stop을 지원하는 메모리 refresh coordinator, 정적 diagnostics, 열기 동작이 없는 workspace와 메모리 login adapter를 주입한다. 상태 항목, 상세 메뉴, 설정 coordinator와 최초 실행 창은 production과 같은 composition을 사용한다. fixture preferences loader는 저장값을 쓰지 않고 런타임의 표시 대상만 Codex 자동 선택으로 만들어 합성 5시간 남은 값 `83%`를 결정적으로 표시한다. fixture 활성화와 최초 실행 reset은 서로 독립이므로 XCUITest의 후속 launch도 같은 외부 경계를 유지하면서 저장된 완료 상태를 읽는다. Release 컴파일에서는 fixture mode 판정을 제거해 동일한 인자도 production 경계로만 이어진다.

하나의 `RefreshPublication` callback은 같은 main-actor transaction에서 상태 frame, menu model, discovered quota ID, 연결 상태와 deadline 후보를 모두 갱신한다. application-open capability는 root 생성 때 한 번 읽어 캐시하며, display 변경과 validity deadline은 메모리 publication을 다시 투영할 뿐 provider 또는 workspace I/O를 만들지 않는다. profile, 수동 조회, quota reset, power와 system resume 명령은 직렬 operation chain을 통해 현재 refresh generation에만 전달된다.

사용자가 executable을 바꾸면 generation을 즉시 올리고 loading presentation으로 전환한 뒤 이전 coordinator의 `stop()` 완료를 기다린다. 그 후 최신 preferences로 provider를 새로 만들며 이전 generation의 늦은 publication은 버린다. 이전 coordinator에 5초 system-resume timer가 대기 중이면 그 phase를 stop 전에 읽고 새 coordinator에 `suspend()`와 `resumeAfterSystemWake()`를 순서대로 적용한다. 따라서 executable 교체가 wake 지연을 즉시 startup 조회로 우회하지 않는다. 실제 application bundle 탐색과 열기는 `NSWorkspaceCodexApplicationAdapter`만 담당하고 shell을 사용하지 않는다.

sleep·wake가 preferences load 또는 executable 교체의 `stop()`과 겹치면 새 coordinator를 request 없는 suspended 상태로 만든 뒤 동일한 직렬 chain의 resume만 적용한다. 따라서 교체 coordinator가 중간에 startup child를 만들지 않는다. 종료는 generation을 먼저 무효화하고 monitor·deadline을 멈춘 뒤 현재 refresh를 한 번 중단하고 진행 중 operation chain을 drain한다. 그 뒤 같은 refresh를 terminal하게 다시 중단하고 chain이 만든 늦은 coordinator도 정리한 다음 settings shutdown을 기다린다. 첫 stop과 경쟁하던 `start()` 또는 갱신이 늦게 재개해 child를 되살려도 두 번째 stop 이후에는 남지 않는다. 중복 `shutdown()` 호출은 이 하나의 shared task 완료를 기다린다.

`CodexGaugeApplicationDelegate`는 Quit 메뉴와 Cmd-Q가 도달하는 `applicationShouldTerminate(_:)`에서 runtime이 아직 없으면 `.terminateNow`를 반환한다. runtime이 있으면 `.terminateLater`를 반환하고 root의 shared async shutdown을 기다린 뒤 요청한 `NSApplication`에 `reply(toApplicationShouldTerminate: true)`를 정확히 한 번 보낸다. drain 중 중복 요청은 같은 task를 공유하고, 완료 뒤 재요청은 추가 shutdown이나 reply 없이 `.terminateNow`로 처리한다. 메뉴의 종료 action은 계속 `NSApplication.terminate(_:)`만 호출하므로 모든 종료 경로가 같은 delegate 경계를 통과한다.

## 3. 도메인 경계

### `UsageProduct`

Codex와 Spark를 나타낸다. App Server의 문자열 ID는 protocol adapter에서 이 타입으로 변환하며 UI에 원문 ID를 흘리지 않는다.

### `QuotaWindow`

한 제품의 primary 또는 secondary quota window다.

- 서버가 준 used percent
- `windowDurationMins`
- reset epoch
- primary 또는 secondary slot

남은 퍼센트 계산과 duration label 정책은 이 값 위의 순수 도메인 함수가 담당한다.
남은 값은 보수적으로 내림하되 `usedPercent < 100`인 유효 quota는 최소 `1%`를 유지하고, 100 이상일 때만 `0%`가 된다.

### `UsageSnapshot`

조회 시각과 제품별 quota 모음을 가진 불변 값이다. 제품별 부분 성공을 표현할 수 있어야 하며 앱 종료 시 폐기한다.

### `DisplayPreference`와 `DisplayFrame`

Preference는 제품 모드와 자동·직접 한도 선택을 표현한다. Frame은 상태바 title을 만들 제품·기간·상태 의미를 보존한다. Core formatter는 locale과 무관한 compact title만 만들고 AppKit의 `StatusAccessibilityFormatter`가 localization resource와 기간 단위 vocabulary로 완전한 접근성 문장을 구성한다. 여러 frame은 builder에서 미리 생성하고 rotation timer는 배열 index만 바꾼다.

직접 선택 ID는 제품과 normalized raw duration의 값 조합이다. `ProductUsageState`는 제품마다 loading, fresh value, stale value와 unavailable을 독립적으로 유지한다. `DisplayFrameBuilder`는 주입받은 현재 시각을 기준으로 reset 도달 또는 24시간 경과 값을 폐기하며 AppKit이나 timer에 의존하지 않는다. 정규화 경계를 우회한 직접 선택에 표시 제품 식별자가 하나도 없더라도 빈 frame 배열을 만들지 않고 해당 제품의 자동 frame으로 복구한다.

### `UsageState`

`loading`, `fresh`, `stale`, `unavailable`을 구분한다. 오류의 종류는 typed reason으로 유지하고 표시 단계에서 현지화된 메시지로 바꾼다.

## 4. 외부 프로세스 경계

### `CodexLocating`

실행 파일은 다음 순서로 찾는다.

1. 사용자가 명시적으로 선택해 저장한 유효 실행 파일
2. `NSWorkspace`가 bundle ID `com.openai.codex`로 찾은 앱의 `Contents/Resources/codex`
3. 지원 목록에 명시된 Homebrew·CLI 설치 위치
4. 찾지 못하면 typed `notFound` 실패

사용자 선택은 권위가 있다. 선택값이 있으면 그 후보만 검증하며 사라졌거나 유효하지 않아도 자동 후보로 fallback하지 않고 `invalidSelection`을 반환한다. 선택값이 없을 때만 bundle 후보와 알려진 경로를 순서대로 검사한다.

`CodexExecutableLocator`는 Foundation만 사용하는 filesystem adapter다. AppKit의 `NSWorkspace`를 직접 알지 않으며, 향후 별도 adapter가 bundle ID `com.openai.codex`로 찾은 application URL을 `bundleApplicationURL`로 주입한다. locator는 그 아래의 `Contents/Resources/codex`를 만든다. 알려진 자동 후보는 system·user Applications의 Codex/ChatGPT app resource, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, 주입된 home의 `.local/bin/codex`다.

모든 후보는 file URL, 존재하는 non-directory, 최종 regular file과 executable permission을 만족해야 한다. symlink는 상대·절대 target을 제한된 hop 수 안에서 표준화해 Homebrew link를 허용하고 broken link, directory target과 cycle은 거부한다. 성공 시 symlink 자체가 아니라 검증된 최종 target URL을 반환한다.

Finder로 실행한 앱은 사용자의 interactive shell `PATH`를 신뢰할 수 없으므로 locator 자체는 PATH 검색이나 shell 호출을 하지 않는다. home과 test용 system root는 constructor로 주입해 단위 테스트가 실제 사용자 directory나 설치 binary를 읽지 않게 한다. 공개 오류는 associated path가 없는 `notFound`와 `invalidSelection`뿐이며 CLI version 실행은 별도 task다. 검증된 파일이 `/usr/bin/env` shebang wrapper인 경우의 interpreter 탐색은 locator가 아니라 아래의 고정 child PATH 정책이 담당한다.

### `CodexUsageProviding`과 `UsageSession`

Provider는 `CodexLocating`이 검증한 URL로 session을 생성한다. `UsageSession`은 actor이며 `Process`, `Pipe`, `FileHandle`을 actor 밖으로 노출하지 않고 다음을 캡슐화한다.

- `Process` 시작과 종료
- stdin/stdout JSONL framing
- request ID 생성과 응답 matching
- `initialize` handshake
- session 최초 조회의 `account/read` 인증 분류
- `account/rateLimits/read`
- timeout, EOF, malformed response와 unsupported method 분류

`start()`는 child를 `app-server` argument 하나로 실행하고 5초 안에 initialize matching response를 받은 뒤 `initialized` notification을 보낸다. 첫 `readRateLimits()`는 `account/read`를 `refreshToken: false`로 한 번 호출한다. 로그인된 ChatGPT 계정 또는 미래의 unknown provider로 분류되면 그 사실만 session 메모리에 기록하고, 같은 burst session의 후속 조회는 15초 제한의 `account/rateLimits/read`만 호출한다. 새 session은 account를 다시 검증한다. signed-out과 지원하지 않는 provider는 서로 다른 typed error다.

한 번에 matching response waiter 하나만 허용하고 ID는 1부터 단조 증가한다. notification, server request와 다른 ID의 response는 소비하지 않고 무시한다. stdout callback은 한 chunk를 읽는 즉시 handler를 해제하고 actor가 framing과 decoding을 끝낸 뒤에만 다시 연결한다. 따라서 noisy child에도 무한 queue나 chunk 유실 없이 pipe backpressure가 적용된다. stderr는 원문을 읽거나 기록하지 않고 null device로 직접 버려 pipe deadlock을 만들지 않는다.

shell을 거치지 않고 실행 파일 URL을 `Process`에 직접 전달한다. production App Server child는 Codex 자체가 인증과 연결을 해석하는 데 필요한 `HOME`, locale, proxy 등을 잃지 않도록 부모 environment를 복사하되 `PATH`만 `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`으로 항상 교체한다. 따라서 Finder의 짧은 PATH나 hostile parent PATH에 의존하지 않으면서 알려진 system·Homebrew 위치의 `#!/usr/bin/env node` wrapper를 지원한다. 다른 parent environment는 필터링하지 않고 신뢰된 Codex child에 기존 상속 의미 그대로 전달하며 디스크, 진단 정보나 로그로 옮기지 않는다.

callback은 복사된 `Data` 또는 exit status만 actor로 보내며 Foundation process 객체를 concurrency 경계 밖으로 옮기거나 `@unchecked Sendable`로 감싸지 않는다. timeout과 종료 grace는 `ContinuousClock`을 사용하고 `waitUntilExit`처럼 cooperative executor를 막는 API는 사용하지 않는다.

명시적 정상 종료 순서는 stdin close, stdout callback 해제, SIGTERM, 제한된 비동기 grace, 필요 시 SIGKILL, handle close다. `stop()`은 pending request를 `stopped`로 정확히 한 번 완료한다. timeout, cancellation, malformed output, 인증 실패처럼 session이 failed 상태가 된 경우에는 호출자가 `stop()`을 빠뜨려도 같은 bounded cleanup을 자동 실행한다. 성공한 재사용 session은 burst 소유자인 `RefreshCoordinator`가 반드시 `stop()`으로 닫는다.

명시적 로컬 검증용 `AppServerSmokeRunner`는 같은 locator 검증 로직, `CodexUsageProvider`와 `UsageSession`을 조합한다. no-argument CLI는 selected URL과 bundle application adapter 없이 현재 home을 주입한 `CodexExecutableLocator`를 만들므로 알려진 macOS application·Homebrew·local CLI 후보만 검사한다. 앱의 `UserDefaults` 선택 경로나 `NSWorkspace` bundle 검색 결과를 읽지 않으며 사용자 지정 위치 지원을 추측하지 않는다. runner는 handshake와 한도 조회를 한 번 실행하고 성공, 실패와 runner Task cancellation 모든 경로에서 하나의 shared stop task를 거쳐 session의 bounded cleanup 완료를 기다린다. 이 Task cancellation 계약은 CLI process signal 처리 계약을 의미하지 않는다. CLI adapter에는 제품별 availability와 typed 실패 범주만 전달하며 `RateLimitReadResult`의 window, 퍼센트, reset, spend-control이나 하위 오류 설명을 문자열로 만들지 않는다. 이 executable은 애플리케이션 composition과 CI 시작 경로에 연결하지 않는다.

## 5. 갱신 상태 머신

`RefreshCoordinator`는 timer, 수동 요청, reset 요청, 시스템 상태를 하나의 actor에서 직렬화한다. 정책 자체는 현재 시각이 포함된 event와 immutable state를 받아 command를 반환하는 순수 reducer다. reducer는 `Task`, timer, process 또는 system notification을 직접 소유하지 않으며 coordinator의 executor가 command를 실행한다.

polling, burst와 backoff deadline은 wall clock 변경의 영향을 받지 않도록 `ContinuousClock.Instant`와 `Duration`으로 계산한다. 서버가 준 quota reset 시각과 제품별 cached value의 `capturedAt + 24시간` 유효기간은 `Date` 기반 별도 `QuotaResetRefreshScheduler`가 처리한다. polling deadline과 wall-clock deadline은 서로 변환하거나 같은 state에 저장하지 않는다.

`QuotaResetRefreshScheduler`는 최신 `[UsageProduct: ProductUsageState]` publication을 입력으로 받는다. fresh와 stale value 각각에서 모든 reset과 해당 value의 24시간 유효기간을 추출하고 loading, unavailable과 quota가 없는 value는 제외한다. 따라서 부분 성공으로 Codex와 Spark의 `capturedAt`이 달라도 오래된 제품의 유효기간이 먼저 예약된다. deadline identity는 typed reason과 정확한 `Date`의 조합이며, 처리하지 않은 가장 이른 시각 하나만 main run loop의 non-repeating timer로 예약한다. production tolerance는 5초이고 `.common` mode를 사용한다. 같은 deadline publication에는 timer를 다시 만들지 않으며 generation 검증으로 publication 교체, sleep 또는 stop 뒤의 늦은 callback을 버린다. 시스템 시계 변경 알림은 명시적으로 구독하고 stop에서 해제한다.

처리 완료 identity 집합은 새 publication마다 최신 후보 집합과 교집합만 유지한다. 따라서 retained history는 항상 현재 제품 상태에서 파생된 후보 수 이하이며 앱 수명에 따라 증가하지 않는다. publication에서 사라졌다가 다시 나타난 지난 identity는 새 현재 후보로 취급하지만, 교체 전에 예약된 timer callback은 별도 generation 검증으로 계속 무시한다.

timer fire, 새 snapshot, wake 또는 시스템 시계 변경에서 현재 wall clock 이하인 deadline을 종류별로 한 번만 처리하고 다음 미래 deadline을 예약한다. 여러 지난 quota reset은 조회 신호 하나로 합치며 24시간 유효기간은 별도의 presentation-only 신호다. reset과 유효기간이 같은 시각이면 하나의 timer에서 유효기간 invalidation, reset refresh 순서로 전달한다. sleep과 stop은 timer를 취소하며 sleep 중 도래한 deadline은 wake 재평가에서 처리한다.

두 typed reason 모두 cached frame을 현재 `Date`로 즉시 다시 만들어 reset 또는 24시간 경계의 값을 `—`로 바꾼다. 평상시 quota reset reason에만 `RefreshCoordinator.refreshAfterQuotaReset()`을 전달하며 coordinator가 자신의 `ContinuousClock`을 읽고 in-flight 요청과 합친다. wall-clock timer callback은 provider I/O를 직접 수행하지 않으며 terminal polling 실패 중에도 24시간 presentation invalidation은 계속 동작한다. 어느 경로에서도 reset 도래를 `100%` 사용으로 추측하지 않는다.

wake composition은 마지막 system suspension 사유가 해제될 때 scheduler의 `systemDidWake()`를 먼저 호출하고 coordinator의 `resumeAfterSystemWake()`를 한 번 호출한다. scheduler 재평가 중 발생한 quota-reset callback은 중단 상태의 coordinator가 intent로 latch하고, 5초 resume timer가 fire할 때 wake request를 quota-reset baseline으로 승격한다. 따라서 callback에서 provider I/O를 직접 실행하지 않으면서 stopped 신호 유실과 별도 wake child 생성을 모두 피한다.

executor는 reducer command를 다음 주입 가능 경계에 연결한다.

- `RefreshClock`은 단조 시각, snapshot용 wall 시각과 deadline sleep을 제공한다.
- `RefreshSessionProviding`은 실제 `CodexUsageProviding`을 감싸며 request command가 있을 때만 session을 만든다.
- `SelectedQuotaSampleSelecting`은 현재 `DisplayPreference`에 따라 비교할 quota만 `SelectedQuotaSamples`로 바꾼다.
- `RefreshPublicationHandler`는 immutable 제품별 상태를 `@MainActor`에 전달한다. process와 timer 작업은 main actor에서 실행하지 않는다.

coordinator는 각각 하나의 timer task와 request task만 보유한다. polling schedule과 5초 system-resume delay는 같은 timer slot을 공유하고 purpose와 generation을 함께 검증한다. 새 schedule은 기존 timer를 취소하고, cancel 또는 stop 뒤 도착한 timer·request completion은 결과와 callback을 갱신하지 않는다. 여러 trigger가 겹쳐도 reducer가 한 request로 합치며 executor가 별도 pending queue를 만들지 않는다.

- reducer state에는 최대 하나의 in-flight request와 하나의 예약만 존재한다.
- request와 예약은 각각 단조 증가 generation을 사용한다. stop이나 재예약 뒤 도착한 이전 generation의 completion과 timer fire는 무시한다.
- 겹친 trigger는 새 요청을 만들지 않고 현재 in-flight 요청으로 합친다. baseline-only reason의 결정적 우선순위는 `quotaReset > wakeBaseline > 기존 reason`이다. 따라서 normal·burst request 중 reset이 도착하거나 reset 뒤 wake가 도착해도 성공은 reset baseline으로만 사용한다.
- 명시적 stop은 현재 request와 예약을 취소하는 command를 내보내고 비교 baseline을 비운다.

### 평상시

- 프리셋의 평상시 간격에 맞춰 session을 시작한다.
- snapshot을 받은 뒤 증가가 없으면 session을 종료한다.
- session 생성, start와 read는 request task에서 실행한다. normal 조회 사이에는 child와 session을 유지하지 않는다.
- timer, 메뉴의 수동 갱신, wake와 reset 요청이 겹치면 하나의 in-flight 작업으로 합친다.
- 시작 후 첫 성공과 wake 성공은 비교 baseline만 교체하고 burst 신호로 사용하지 않는다.
- `refreshAfterQuotaReset()`은 reset 도래를 감지한 외부 adapter가 호출하는 단발 seam이다. 중복 호출은 합치고 성공값을 새 baseline으로만 사용해 burst를 시작하지 않는다.
- 동일한 프리셋으로의 변경은 아무 state나 command도 바꾸지 않는다.
- 자동 프리셋 변경 시 in-flight 요청은 유지하고 완료 뒤 새 간격을 사용한다. 요청이 없으면 retry가 아닌 기존 예약을 취소하고 변경 시각부터 새 평상시 또는 burst 간격으로 예약한다.
- 수동 프리셋 진입은 예약과 in-flight 요청을 취소하고 burst와 연속 실패 횟수를 지운다. baseline과 coordinator 실행 상태는 유지하며 취소 뒤 늦게 도착한 completion은 generation 검증으로 무시한다.
- 수동에서 자동으로 바꾸면 baseline을 유지하고 즉시 요청 없이 변경 시각부터 평상시 예약을 만든다.

### burst

- 비교 표본은 제품, raw duration과 reset 시각을 identity로 하고 내림한 정수 used percent를 값으로 사용한다.
- 같은 identity의 선택 quota가 하나라도 증가하면 현재 session을 유지한다.
- 값이 같으면 deadline을 연장하지 않는다. 다른 quota의 증가가 함께 있지 않다면 감소, 선택 identity 변경과 reset cycle 변경은 baseline을 교체하고 burst를 끝낸다.
- 프리셋의 burst 간격으로 최대 5분간 재조회한다.
- 추가 증가 시 종료 deadline을 5분 연장한다.
- deadline 도달 또는 연속 3회 실패 시 session을 종료한다.
- 증가를 발견한 request의 session 하나를 burst가 끝날 때까지 재사용한다. burst tick은 account 검증이 끝난 같은 session에서 rate-limit 조회만 반복한다.
- 조회 실패 시 session은 즉시 종료한다. retry가 필요하면 backoff 이후 새 transient session을 만들며 실패한 child를 재사용하지 않는다.

### backoff

일시 실패는 30초, 1분, 2분, 4분, 8분, 16분, 30분 순으로 지수 backoff하고 이후 30분으로 제한한다. 성공하면 실패 횟수를 지우고 사용자가 선택한 프리셋으로 돌아간다. 수동 프리셋은 일시 실패에도 자동 재시도를 예약하지 않는다. 로그아웃, 실행 파일 미발견과 protocol 비호환은 무한 재시도하지 않고 사용자 조치 상태로 전환한다.

성공 publication은 제품마다 독립적으로 갱신한다. `available` 또는 유효 window가 있는 `partial` 제품은 fresh가 되고 해당 제품의 마지막 성공 시각만 갱신한다. 정상 `unavailable` 제품의 empty window는 이전 표시값을 지우고 unavailable로 전환하되 제품별 마지막 성공 시각은 진단을 위해 유지할 수 있다. malformed 제품의 empty window만 이전 성공값과 제품별 성공 시각이 있으면 stale로 유지하며, 이전 값이 없으면 unavailable로 표시한다. 유효 window가 하나도 없는 성공 응답은 quota 값의 전역 마지막 성공 시각을 갱신하지 않지만, 별도 `lastAcceptedRateLimitResponse`에 정상 protocol 교환 시각을 기록한다. 전체 조회 실패도 이전 값은 stale로 보존하며 UI에는 raw error가 아닌 `RefreshFailure`만 전달한다. spend-control을 포함한 typed product detail과 snapshot은 메모리에만 둔다.

응답 object에 quota container가 없거나 비어 있는 경우는 정상적으로 연결된 empty quota로 받아들이고 설정 연결 상태를 `연결됨`으로 표시한다. `rateLimitsByLimitId` 또는 legacy `rateLimits` container 자체가 object가 아니면 `RateLimitResponseStatus.incompatible`로 분류한다. coordinator는 이를 terminal protocol failure로 바꿔 자동 재시도를 멈추며, 해당 응답을 정상 교환 시각이나 quota 성공 시각으로 기록하지 않는다. 개별 제품 bucket 또는 window의 malformed는 outer container 비호환으로 승격하지 않아 다른 제품의 부분 성공을 보존한다.

### 시스템 상태

- sleep 또는 화면 잠금 알림을 받으면 timer와 child를 종료한다.
- wake 또는 unlock 후 5초 뒤 단발 조회한다.
- sleep 중 놓친 tick을 연속 실행하지 않는다.
- wake 조회에서 이전 값보다 증가했더라도 이를 burst 신호로 사용하지 않는다.
- Low Power Mode에서는 평상시 10분, burst 60초보다 빠르게 실행하지 않는다.

AppKit의 `SystemActivityMonitor`는 `NSWorkspace`의 sleep, wake와 user session 활성 상태 알림 및 `ProcessInfo`의 power-state 알림만 구독한다. 시작 시에도 현재 Low Power Mode를 한 번 전달하고 이후 알림의 payload를 신뢰하지 않고 현재 값을 다시 읽는다. 이 adapter는 지연 timer나 process를 소유하지 않고 typed `SystemActivityEvent`만 내보낸다. observer 등록은 idempotent하며 명시적 `stop()`에서 모두 해제한다. 5초 wake 지연, 중복 resume 병합과 session 종료는 `RefreshCoordinator`가 monotonic clock 위에서 담당한다.

executor의 `suspend()`는 reducer stop command를 통해 timer, in-flight request와 retained burst session을 모두 정리한다. `resumeAfterSystemWake()`는 같은 단조 timer slot에서 중복 resume 요청을 합치고 5초 뒤 한 번만 wake-baseline request를 만든다. 수동 profile에서는 running 상태만 복구하고 자동 조회는 만들지 않는다. `setLowPowerMode(_:)`는 reducer에 power 상태를 전달해 기존 retry가 아닌 schedule을 제한된 간격으로 교체한다. 앱 composition은 `SystemActivityEvent`를 이 세 API에 연결하며 별도 polling 정책을 만들지 않는다.

system suspension 중 또는 5초 resume timer가 대기하는 동안 `refreshAfterQuotaReset()`이 도착하면 coordinator가 typed reset intent만 메모리에 latch한다. 중복 resume는 기존 deadline을 연장하지 않고, timer가 fire하면 running 상태를 복구한 뒤 wake request를 같은 generation의 quota-reset baseline으로 승격한다. 따라서 child는 하나만 시작하며 reset 신호 유실, wake와 reset의 이중 조회 및 잘못된 burst를 모두 피한다. 명시적 stop과 새 start는 남아 있는 reset intent를 폐기한다.

composition의 `ApplicationActivityReducer`는 sleep과 session lock을 중복 가능한 set으로 유지한다. 첫 중단 사유가 시작될 때만 coordinator에 suspend command를 보내고 마지막 사유가 끝날 때만 resume command를 보낸다. 각 원시 알림은 별도로 `.sleeping`과 `.screenLocked` rotation pause를 즉시 갱신하므로 두 사유가 겹쳐도 마지막 사유가 해제될 때까지 순환이 재개되지 않는다. 중복 notification이나 존재하지 않는 사유의 종료는 polling state에서는 no-op이므로 wake 뒤에도 여전히 잠긴 session에서 polling이 먼저 재개되지 않는다.

reset 절대 시각과 제품별 24시간 만료는 wall clock `Date`이므로 polling의 단조 deadline으로 변환하지 않는다. `QuotaResetRefreshScheduler`가 clock change, publication 교체와 sleep/wake에 맞춰 별도 one-shot을 재등록하며 이 분리는 polling timer가 wall-clock 변경으로 앞당겨지거나 지연되는 것을 막는다.

## 6. AppKit 생명주기

### 앱 bundle 경계

root `Package.swift`가 모든 domain, protocol, refresh, settings와 AppKit runtime source의 기준이다. `CodexGauge.xcodeproj`의 application target은 같은 domain/runtime source를 target membership으로 복제하지 않고 local package product `CodexGaugeAppKit`을 연결하며, `App/CodexGauge`의 `main.swift`, `Info.plist`와 `Assets.xcassets`만 직접 소유한다.

application bundle은 macOS 13 이상, Swift 6 language mode, `LSUIElement=true`, Hardened Runtime 활성화와 App Sandbox 비활성화를 명시한다. Release는 standard architecture와 `ONLY_ACTIVE_ARCH=NO`로 Apple Silicon·Intel universal 산출물을 만든다. shared `CodexGauge` scheme은 package 경계를 확인하는 XCTest unit smoke와 최초 실행 설정 창 XCUITest를 함께 제공한다.

### 상태 항목

`StatusItemController`는 앱 실행 동안 유지되며 domain `DisplayFrame`을 AppKit 표현으로 바꾸는 얇은 경계다. production의 `SystemStatusItemPresenter`만 `NSStatusItem`을 알고 controller test는 주입한 presenter를 사용해 전역 status bar를 만들지 않는다. 상세 메뉴는 별도 adapter가 메모리 snapshot으로 구성하며 조회 완료를 기다리지 않는다.

`StatusFrameRenderer`는 기존 `DisplayFrameFormatter`의 문자열과 접근성 의미를 그대로 사용한다. bracket token만 작은 단색 rounded-border template image로 치환하고 숫자 영역에는 monospaced digit font를 적용한다. 기간 배지는 label과 effective appearance를 key로 캐시하며 캐시는 작은 고정 상한을 갖는다. 상태 항목에는 별도 앱 아이콘이나 animation을 넣지 않는다.

controller는 각 현재 frame의 제품·기간·비교 구조를 보존하고 모든 quota 값을 `stale(100)`으로 바꾼 최악값 prototype을 순수 변환으로 항상 만든다. 선택되었지만 현재 응답에 없는 대안은 호출자가 별도 prototype으로 더할 수 있다. 실제 frame과 모든 prototype을 한 번 렌더링하고 최대 측정 폭에 12pt를 더해 `NSStatusItem.length`를 고정하며, 최대 문자열을 자르는 임의 상한은 두지 않는다. 여러 frame은 attributed title과 접근성 label까지 미리 렌더링한다. `StatusFrameRotation`은 5초 timer(tolerance 1초)에서 배열 index와 presenter만 갱신하므로 tick에서 formatter, layout 측정 또는 I/O를 호출하지 않는다.

frame이 하나면 scheduler에 timer 생성이나 취소 command를 보내지 않는다. 메뉴 열림, 화면 잠금, sleep, VoiceOver, Reduce Motion은 set으로 중첩 관리한다. 하나라도 활성화되면 timer를 취소하며 모든 사유가 해제되면 frame 0을 즉시 표시하고 새 5초 주기를 시작한다. 중단 중 경과한 tick은 실행하지 않는다.

`AssistiveDisplayMonitor`는 `NSWorkspace`의 accessibility display options 변경 notification과 `isVoiceOverEnabled` KVO만 관찰한다. 시작할 때 VoiceOver와 Reduce Motion의 현재 값을 하나의 immutable `AssistiveDisplayState`로 전달하고, 이후 두 관찰 경계 중 하나가 바뀌면 전체 상태를 다시 읽어 실제 값이 달라진 경우에만 changed event를 보낸다. observer 등록은 idempotent하며 `stop()`은 notification token과 KVO observation을 모두 해제한다.

실제 `NSWorkspace` 접근은 주입 가능한 `AssistiveDisplayStateSourcing` 뒤에 둔다. monitor는 timer, status item, provider 또는 I/O를 소유하지 않으며 typed state callback만 composition root에 제공한다. composition은 두 boolean을 각각 `.voiceOver`와 `.reduceMotion` rotation pause reason으로 연결하되 monitor와 `StatusItemController`를 직접 결합하지 않는다.

상세 메뉴는 `QuotaDetailsMenuInput → QuotaDetailsMenuModel → StatusMenuController`로 분리한다. 순수 builder는 메모리의 제품별 `ProductUsageState`, typed issue와 마지막 성공 시각만 받아 Codex·Spark section, 모든 quota window, 절대 reset 시각과 action group을 만든다. stale, partial과 unavailable은 제품별로 독립 유지하며 값을 알 수 없는 상태를 `0%`로 만들지 않는다. date formatter와 localization value를 주입해 합성 시각으로 검증할 수 있다.

`StatusMenuController`는 상태 갱신 시 완성된 immutable model로 `NSMenu`를 미리 구성하고 `SystemStatusItemPresenter`에 연결한다. menu open callback에서는 model 생성, 날짜 formatting 또는 snapshot 조회를 하지 않고 `.menuOpen` rotation pause만 설정하며 close에서 해제한다. action은 refresh, Codex 열기·선택, 설정과 종료 closure로 주입하므로 UI adapter가 provider, process 또는 설정 창을 직접 알지 않는다. production composition은 이 action을 application coordinator의 현재 generation과 settings runtime에 연결한다.

제품별 `ProductRateLimits`에 보존된 spend-control은 presentation adapter가 dependency-free `QuotaMenuSpendControl`로 축약해 menu input에 넣는다. `reached == true`가 남은 비율보다 우선하고, 비율만 있으면 남은 정수 퍼센트로, 명시적 `reached == false`만 있으면 남은 비율을 알 수 없는 미도달 상태로 표현한다. 순수 menu builder가 이를 quota window 뒤의 별도 비활성 행으로 현지화하며, malformed·missing 값은 행을 만들지 않는다. 이 dictionary는 제품별로 독립적이고 `DisplayFrameBuilder`, status width prototype과 rotation controller에는 전달되지 않는다.

### 설정 창

`CodexGaugeSettings`의 `SettingsFormState`, reducer와 presenter가 표시 제품, 자동·직접 선택, 발견·누락 quota 행, 갱신 프리셋과 로그인 실행 의도를 UI와 무관한 immutable value로 다룬다. AppKit view controller는 이 결과를 programmatic `NSStackView`와 Auto Layout에 투영하고 사용자 event를 reducer로 돌려보내는 얇은 adapter다. 발견한 quota 식별자는 메모리 provider로 주입하며 UI가 provider나 process를 직접 호출하지 않는다.

`SettingsWindowCoordinator`는 창을 요청할 때만 약 440pt 폭의 독립 `NSWindowController`를 만들고 한 번에 하나만 보유한다. 변경된 `SettingsFormValues`는 actor repository에 순서대로 전달하며 repository가 저장 시점의 최신 executable URL과 최초 실행 field에 원자적으로 merge한다. 따라서 창이 열린 동안 다른 owner가 갱신한 숨은 field를 오래된 form state가 덮어쓰지 않는다. 창을 닫은 뒤 다시 열 때는 진행 중인 저장을 먼저 마치고 `UserDefaults`를 새로 읽는다. window close callback은 coordinator의 강한 참조와 AppKit content graph를 제거한다. 로그인 실행 UI는 intent만 저장하며 `SMAppService` 호출은 launch adapter 경계에 남긴다. quota snapshot이나 오류 원문은 저장하지 않는다.

로그인 실행 checkbox event는 generic form save와 `onLaunchAtLoginIntentRequested`로 분기한다. 전자는 저장된 의도만 merge하고 후자는 같은 boolean이 반복되어도 application root에 사용자 요청을 전달한다. 따라서 registration·unregistration 실패 뒤 저장 의도는 이미 원하는 값이어도 실제 상태와의 mismatch를 재시도할 수 있다. 결과는 반대 방향의 `LaunchAtLoginSettingsState` publication으로만 열린 창에 들어오며 view나 settings coordinator가 `SMAppService`를 직접 호출하지 않는다.

각 form event는 저장 queue와 별도로 주입된 `onSettingsFormValuesChanged` callback에도 전달한다. composition root는 이 seam을 현재 display preference, refresh profile과 로그인 실행 intent에 적용하며 설정 UI가 runtime controller를 직접 알지 않게 한다. 연결 상태 publication과 종료 drain은 `ApplicationSettingsRuntime` 경계에 분리되고 adapter가 settings coordinator의 I/O 없는 상태 갱신과 terminal shutdown API에 직접 연결한다.

초기 quota 조회가 열린 설정 창보다 늦게 끝나면 composition root는 `updateDiscoveredQuotaIDs(_:)`로 발견 목록만 교체한다. 이 system update는 remembered selection과 form value를 보존하고 UI row만 다시 만들며 저장 queue와 runtime preference callback을 호출하지 않는다. 창이 없을 때는 아무 객체도 만들지 않고 다음 `showSettings()`가 provider의 최신 목록을 읽는다.

연결 영역은 `ConnectionDiagnosticsInspector`가 만든 immutable `ConnectionDiagnosticsSnapshot`만 소비한다. Inspector actor는 locator가 검증한 URL을 내부에서만 사용해 `CodexCLIVersionProbe`를 실행하고, UI에는 자동·사용자 선택 출처, 일반화된 위치 category, 제한된 basename, CLI version token과 typed 상태만 넘긴다. coordinator는 composition이 전달한 최신 연결 상태와 revision을 별도로 보존해 열린 화면과 진단 복사 snapshot에 I/O 없이 즉시 반영한다. CLI probe completion은 revision이 바뀌었으면 path·version 결과만 취하고 연결 상태는 최신 값을 다시 합쳐, probe 시작 시점의 상태가 UI를 되돌리지 못하게 한다. 최초 snapshot도 같은 최신 상태로 구성해 창을 표시한 직후 화면과 복사 report가 일치한다.

`ConnectionStatusResolver`는 메모리에 있는 `RefreshPublication`의 checking, quota 값 성공 시각, 정상 rate-limit 응답 시각과 typed failure를 연결 상태로 바꾸므로 설정을 열기 위해 별도 App Server quota 조회를 만들지 않는다. 정상 empty quota도 마지막 accepted 응답 시각으로 `연결됨`이 되지만 container 비호환과 typed failure가 이 상태보다 우선한다.

`CodexCLIVersionProbe`는 shell 없이 검증된 executable을 `--version` 인자 하나로 실행하는 background actor다. stdin과 stderr는 `/dev/null`에 연결하고 stdout은 한 chunk씩 backpressure를 유지하며 최대 4 KiB까지만 받는다. production child environment는 App Server session과 같은 단일 safe PATH 상수를 사용하되, 인증이 필요 없는 진단 경계이므로 부모의 `LANG`, `LC_ALL`, `LC_CTYPE` 중 존재하는 값만 새 dictionary에 복사한다. 고정 순서는 system interpreter를 Homebrew·Intel Homebrew 위치보다 먼저 찾으면서 `#!/usr/bin/env …` wrapper도 지원한다. 부모의 `PATH`, `HOME`과 그 밖의 environment는 전달하지 않는다.

nvm, asdf와 Volta처럼 사용자 home 아래의 runtime manager path 탐색은 v0.1의 비목표다. 해당 runtime에만 의존하는 wrapper는 사용자가 executable로 선택해도 version probe가 `processFailed`가 될 수 있으며, 이를 해결하기 위해 interactive shell이나 부모 PATH를 실행 경계로 가져오지 않는다.

Parser는 선택적인 마지막 LF 또는 CRLF를 제외한 전체 출력이 정확히 `codex-cli <version>` 또는 `codex <version>` 한 줄인지 확인한다. version은 숫자 세 component와 선택적인 점 구분 prerelease·build identifier로 구성되고 최대 64자다. 따라서 출력의 다른 위치에서 그럴듯한 숫자를 찾거나 account 문구, 추가 숫자, 빈 component와 여러 줄을 허용하지 않는다. 원문 stdout, exit 설명과 경로는 보존하지 않는다.

Probe는 2초 timeout과 제한된 terminate/SIGKILL grace로 자신이 직접 시작한 child를 정리한다. Foundation `Process`가 direct child PID만 소유하는 경계에서 별도 process group을 만들거나 임의의 descendant tree를 추적·종료하는 것은 v0.1의 비목표다. version command가 descendant를 만드는 executable은 지원 대상으로 가정하지 않는다.

`SettingsFormViewController`의 `Codex 선택…`과 `진단 정보 복사`는 closure로 주입된다. 실제 `NSOpenPanel`과 `NSPasteboard` 접근은 각각 `NSOpenPanelCodexExecutableSelector`, `SystemDiagnosticClipboardWriter`에만 있다. panel adapter는 sheet와 독립 panel 모두 명시적으로 dismiss할 수 있고, cancellation과 AppKit completion의 경쟁을 session 하나가 중재해 continuation을 정확히 한 번만 완료한다. 메뉴의 선택 action도 public `requestExecutableSelection()`을 호출해 필요하면 설정 창을 먼저 열고 같은 panel·저장 경로를 재사용한다. 선택 URL 저장은 repository actor가 최신 form·최초 실행 값을 보존하며 merge하고 외부 executable-selection callback이 provider 재구성을 요청할 수 있다. 선택 task는 generation으로 식별해 닫힌 창의 늦은 결과가 새 panel task를 지우지 못하게 하며, 저장을 시작한 선택은 창이 닫혀도 runtime callback까지 완료한다. commit 시점에는 panel을 열었던 창이 아니라 현재 `activeWindowController`를 `checking` snapshot으로 바꾸고 새 URL diagnostics를 예약하므로, 저장 중 닫고 다시 연 창도 이전 path·status에 머물지 않는다. pending selection은 window controller를 강하게 보유하지 않는다. 창 close는 진행 중 diagnostics task를 generation과 cancellation로 무효화하고, 다음 진단은 이전 CLI process cleanup task의 완료를 기다린 뒤 시작한다.

`shutdown()`은 앱 종료용 terminal drain이며 동시 호출은 같은 작업을 기다린다. form save queue를 보존하고 diagnostics cancellation의 cleanup을 기다리며, 미확정 panel을 dismiss하고 이미 commit을 시작한 executable 저장과 runtime callback을 완료한다. `showSettings()`는 optional 결과이며 시작 전과 form-save·repository await 뒤마다 terminal state와 caller cancellation을 확인한다. shutdown과 경쟁해 만든 창은 즉시 닫고 `nil`을 반환하며, shutdown 이후 호출도 새 graph를 만들지 않는다. diagnostics refresh와 selection 요청도 terminal state에서 무시한다.

window controller와 view controller가 실제로 해제되는지는 weak-reference 단위 테스트로 검증한다.

### 로그인 시 실행

`LaunchAtLoginController`는 main actor에서 `SMAppService.mainApp`을 감싸고 `disabled`, `enabled`, `requiresApproval`, `unavailable`의 비식별 상태만 UI에 제공한다. 이미 원하는 상태에서는 register 또는 unregister를 반복하지 않는다. 승인 대기 상태에서 enable 요청은 재등록하지 않고 로그인 항목 System Settings 동작을 별도로 제공하며, disable 요청은 등록을 해제한다.

macOS 호출이 실패해도 호출 직후 시스템 상태가 이미 요청 결과가 되었다면 경쟁 상태의 성공으로 취급한다. 그 밖의 NSError domain, code와 description은 버리고 registration, unregistration, unavailable의 typed failure만 전달한다. `LaunchAtLoginSettingsState`는 이 실제 status와 optional typed failure만 보존하고, checkbox의 off·on·mixed 상태, 활성 여부와 System Settings recovery 가시성을 순수하게 도출한다.

설정의 `launchAtLoginIntent`는 사용자가 마지막으로 요청한 값일 뿐 실제 checkbox 상태가 아니다. composition은 시작 시 저장된 intent를 한 번 적용해 defaults와 실제 OS 상태의 drift를 복구하고, 사용자 요청도 같은 직렬 operation chain에서 adapter에 적용한다. 성공과 typed 실패는 application root가 `ApplicationSettingsRuntime`으로 즉시 publish하며, 설정 창이 닫혀 있으면 작은 최신 값만 보존한다. 창을 다시 표시하거나 `NSApplicationDelegate.applicationDidBecomeActive`가 전달될 때 semantic provider가 현재 system status를 읽는다. status가 그대로이면 마지막 typed 실패를 유지하고 바뀌었으면 obsolete failure를 제거해 열린 창에 publish한다. 이 재표본은 `SMAppService.status`만 읽고 등록·해제를 만들지 않는다. fixture는 메모리 adapter와 같은 흐름을 사용해 `SMAppService` 변경을 만들지 않는다.

### 최초 실행

production factory는 `FirstLaunchSettingsCoordinator`를 refresh 시작 뒤의 startup hook에 연결한다. coordinator는 process 수명 동안 자동 표시를 한 번만 시도하며, repository의 최신 `hasCompletedFirstLaunch`가 false일 때만 기존 설정 창 runtime을 호출한다. 별도 onboarding controller는 만들지 않는다.

`ApplicationSettingsRuntime.showSettings()`는 window controller 생성 여부가 아니라 실제 `NSWindow.isVisible` 결과를 돌려준다. 표시 전에 caller가 취소되거나 shutdown과 경쟁해 `nil`이 되거나 창이 visible 상태가 아니면 완료로 기록하지 않는다. `true`를 받은 순간부터는 caller cancellation을 다시 완료 조건으로 사용하지 않고 repository actor의 `markFirstLaunchCompleted()`가 끝날 때까지 기다린다. application shutdown도 취소한 startup operation을 drain하므로, 사용자가 본 설정 창이 다음 실행에 다시 자동 표시되는 경쟁을 만들지 않는다. 이 read-modify-write는 저장 시점의 표시·refresh·로그인·선택 executable 값을 모두 보존하고 최초 실행 값만 true로 바꾸며, 이미 완료된 경우에는 다시 쓰지 않는다.

UI 테스트용 `--codex-gauge-ui-test-reset-first-launch` argument는 production defaults에서도 안전한 field-only seam이다. defaults domain을 지우지 않고 최초 실행 완료 여부만 false로 되돌리며, 표시 설정·refresh profile·로그인 실행 의도·선택 executable을 그대로 둔다. reset, form save, executable save와 완료 기록은 같은 repository actor에서 직렬화해 서로의 field를 잃지 않는다. 비슷한 이름의 argument는 인식하지 않는다.

통합 UI fixture argument와 reset seam은 독립적으로 판정한다. 최초 실행 XCUITest의 첫 launch만 두 인자를 함께 사용하고 후속 launch는 fixture만 유지한다. 합성 publication은 메모리에서만 유지되고 quota payload나 선택 경로를 defaults에 쓰지 않는다. fixture refresh가 종료되면 이후 start·수동 갱신·wake 요청은 새 publication을 만들지 않으며, executable 변경으로 새 fixture generation이 필요할 때만 새 coordinator를 구성한다.

Quit 또는 Command-Q가 들어오면 AppDelegate는 `.terminateLater`를 반환하고 같은 비동기 runtime shutdown을 공유한다. 설정 저장과 child 정리가 끝난 뒤 요청한 `NSApplication`에 성공 답변을 정확히 한 번 보내며, runtime 생성 전이나 drain 완료 뒤의 요청은 즉시 종료한다.

## 7. 설정 저장

`CodexGaugeSettings`의 `AppPreferences`는 다음과 같은 비밀이 아닌 값만 가진 immutable `Sendable` value다.

- 표시 제품
- 자동 또는 직접 한도 식별자
- 갱신 프리셋
- 로그인 시 실행 의도
- 사용자가 선택한 Codex 실행 파일 경로
- 최초 실행 완료 여부

`AppPreferencesRepository` actor만 주입받은 `UserDefaults`에 접근한다. 전체 값을 `io.github.symflee.codex-gauge.preferences`라는 하나의 namespaced key에 versioned JSON `Data`로 저장해 같은 defaults domain의 다른 key를 건드리지 않는다. 일반적인 전체 `load`·`save` 외에 설정 form, 선택 executable과 최초 실행 완료 저장은 각각 담당 field만 받아 최신 전체 값에 actor 내부에서 read-modify-write한다. 세 연산에는 suspension point가 없어 동시 호출도 직렬화되며 서로의 최신 값을 잃지 않는다. 최초 실행 완료 저장은 true에서 no-op인 단방향·멱등 연산이다.

저장 envelope에는 schema version을 별도로 포함한다. 현재 version 1은 display 설정을 중첩하고 나머지 허용 필드를 top-level에 둔다. version 0은 `displayProductMode`, `displayQuotaSelection`, `manualQuotaSelections`가 분리된 초기 flat schema이며 순수 decoder에서 현재 `AppPreferences`로 migration한다. `AppPreferences`는 생성 경로와 schema version에 관계없이 manual selection을 표시 제품과의 교집합으로 제한하고, 교집합이 비면 automatic으로 정규화한다. manual selection은 제품 raw value 오름차순, 같은 제품 안에서는 양수 raw duration 오름차순과 기간 미상 마지막 순서로 정렬해 항상 같은 byte를 만든다.

version이나 root가 해석되지 않거나 미래 version이면 전체 기본값을 사용한다. 현재 또는 version 0 schema의 개별 enum, boolean, manual item과 URL이 잘못되면 해당 field만 기본값으로 복구하고 나머지는 유지한다. 선택한 executable은 file URL만 받는다. quota snapshot, used/remaining percent, reset, account/error와 raw response는 schema에 없으며 repository는 payload나 경로를 log 또는 description에 넣지 않는다.

## 8. 보안과 개인정보 경계

- Codex 인증 파일과 브라우저 cookie를 읽지 않는다.
- token, 이메일, raw JSONL, 세션 로그와 quota history를 저장하지 않는다.
- stderr는 pipe deadlock을 방지하기 위해 소비하되 민감정보가 제거되지 않은 채 `OSLog`에 쓰지 않는다.
- 진단 정보에는 앱 버전, macOS 버전, 선택 경로의 유효 여부, CLI 버전, 마지막 typed error code만 포함한다.
- 사용자 경로는 UI에서만 제한된 basename 또는 일반화된 위치로 축약한다. 진단 복사에는 basename 없이 출처와 일반화된 category만 포함한다.
- telemetry, 외부 analytics와 crash SDK를 사용하지 않는다.

## 9. 자원 예산

- 기본 자동 선택에서는 rotation timer가 존재하지 않아야 한다.
- 균형 프리셋의 10분 idle 동안 시작 조회를 포함해 child 시작은 최대 4회다.
- idle 조회 사이에는 App Server child가 존재하지 않아야 한다.
- 하나의 burst에서는 child를 한 번만 시작한다.
- rotation tick은 title 교체 외 I/O를 하지 않는다.
- 설정 창을 닫은 뒤 관련 객체 graph를 해제한다.
- 최종 idle RSS는 빈 AppKit scaffold 기준보다 8MiB 이상 증가하지 않는 것을 목표로 한다.
- 10분 idle 평균 CPU는 0.1% 이하를 목표로 한다.

이 값은 보장 문구가 아니라 Release build와 Instruments로 검증할 성능 acceptance criterion이다. 측정 환경과 결과는 [개발 문서](development.md)에 기록한다.
