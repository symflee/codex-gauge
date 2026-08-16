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

`RefreshPresentationAdapter`는 coordinator가 발행한 immutable 제품별 결과를 하나의 시각에 맞춰 상태바 frame, 상세 메뉴 input과 설정용 discovered quota ID로 투영한다. 전역 실패는 두 제품에 같은 복구 사유를 적용하되 partial·malformed 같은 제품별 issue와 마지막 성공 시각은 서로 오염시키지 않는다. adapter는 AppKit, process, timer와 I/O를 알지 않으며 초기 loading 상태에서 임의의 오류나 quota를 만들지 않는다.

composition은 `NSWorkspace`에서 실제 application bundle을 찾았는지를 boolean capability로 presentation adapter에 전달한다. typed not-found·invalid-selection 오류 또는 열 application 부재는 `Codex 선택…` action을 만들고, bundle을 열 수 있을 때만 `Codex 열기`를 만든다. CLI 조회 성공을 application open 가능 상태로 추측하지 않는다.

SwiftPM은 Core, Protocol, Refresh, Settings와 AppKit 모듈의 단일 source of truth다. Xcode application target은 이 package의 `CodexGaugeAppKit` product와 `App/CodexGauge`의 bundle metadata만 소유한다. 같은 Swift 소스를 package와 Xcode target membership에 중복 등록하지 않는다.

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

### `UsageSnapshot`

조회 시각과 제품별 quota 모음을 가진 불변 값이다. 제품별 부분 성공을 표현할 수 있어야 하며 앱 종료 시 폐기한다.

### `DisplayPreference`와 `DisplayFrame`

Preference는 제품 모드와 자동·직접 한도 선택을 표현한다. Frame은 상태바 title, 배지 정보와 완전한 접근성 문자열로 구성된다. 여러 frame은 builder에서 미리 생성하고 rotation timer는 배열 index만 바꾼다.

직접 선택 ID는 제품과 normalized raw duration의 값 조합이다. `ProductUsageState`는 제품마다 loading, fresh value, stale value와 unavailable을 독립적으로 유지한다. `DisplayFrameBuilder`는 주입받은 현재 시각을 기준으로 reset 도달 또는 24시간 경과 값을 폐기하며 AppKit이나 timer에 의존하지 않는다.

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

Finder로 실행한 앱은 사용자의 interactive shell `PATH`를 신뢰할 수 없으므로 PATH 검색이나 shell 호출을 하지 않는다. home과 test용 system root는 constructor로 주입해 단위 테스트가 실제 사용자 directory나 설치 binary를 읽지 않게 한다. 공개 오류는 associated path가 없는 `notFound`와 `invalidSelection`뿐이며 CLI version 실행은 별도 task다.

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

shell을 거치지 않고 실행 파일 URL을 `Process`에 직접 전달한다. callback은 복사된 `Data` 또는 exit status만 actor로 보내며 Foundation process 객체를 concurrency 경계 밖으로 옮기거나 `@unchecked Sendable`로 감싸지 않는다. timeout과 종료 grace는 `ContinuousClock`을 사용하고 `waitUntilExit`처럼 cooperative executor를 막는 API는 사용하지 않는다.

명시적 정상 종료 순서는 stdin close, stdout callback 해제, SIGTERM, 제한된 비동기 grace, 필요 시 SIGKILL, handle close다. `stop()`은 pending request를 `stopped`로 정확히 한 번 완료한다. timeout, cancellation, malformed output, 인증 실패처럼 session이 failed 상태가 된 경우에는 호출자가 `stop()`을 빠뜨려도 같은 bounded cleanup을 자동 실행한다. 성공한 재사용 session은 burst 소유자인 `RefreshCoordinator`가 반드시 `stop()`으로 닫는다.

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

성공 publication은 제품마다 독립적으로 갱신한다. `available` 또는 유효 window가 있는 `partial` 제품은 fresh가 되고 해당 제품의 마지막 성공 시각만 갱신한다. 현재 응답에서 unavailable·malformed인 제품은 이전 성공값과 제품별 성공 시각이 있으면 stale로 유지한다. 유효 window가 하나도 없는 성공 응답은 전역 마지막 성공 시각도 갱신하지 않는다. 전체 조회 실패도 이전 값은 stale로 보존하며 UI에는 raw error가 아닌 `RefreshFailure`만 전달한다. spend-control을 포함한 typed product detail과 snapshot은 메모리에만 둔다.

### 시스템 상태

- sleep 또는 화면 잠금 알림을 받으면 timer와 child를 종료한다.
- wake 또는 unlock 후 5초 뒤 단발 조회한다.
- sleep 중 놓친 tick을 연속 실행하지 않는다.
- wake 조회에서 이전 값보다 증가했더라도 이를 burst 신호로 사용하지 않는다.
- Low Power Mode에서는 평상시 10분, burst 60초보다 빠르게 실행하지 않는다.

AppKit의 `SystemActivityMonitor`는 `NSWorkspace`의 sleep, wake와 user session 활성 상태 알림 및 `ProcessInfo`의 power-state 알림만 구독한다. 시작 시에도 현재 Low Power Mode를 한 번 전달하고 이후 알림의 payload를 신뢰하지 않고 현재 값을 다시 읽는다. 이 adapter는 지연 timer나 process를 소유하지 않고 typed `SystemActivityEvent`만 내보낸다. observer 등록은 idempotent하며 명시적 `stop()`에서 모두 해제한다. 5초 wake 지연, 중복 resume 병합과 session 종료는 `RefreshCoordinator`가 monotonic clock 위에서 담당한다.

executor의 `suspend()`는 reducer stop command를 통해 timer, in-flight request와 retained burst session을 모두 정리한다. `resumeAfterSystemWake()`는 같은 단조 timer slot에서 중복 resume 요청을 합치고 5초 뒤 한 번만 wake-baseline request를 만든다. 수동 profile에서는 running 상태만 복구하고 자동 조회는 만들지 않는다. `setLowPowerMode(_:)`는 reducer에 power 상태를 전달해 기존 retry가 아닌 schedule을 제한된 간격으로 교체한다. 앱 composition은 `SystemActivityEvent`를 이 세 API에 연결하며 별도 polling 정책을 만들지 않는다.

system suspension 중 또는 5초 resume timer가 대기하는 동안 `refreshAfterQuotaReset()`이 도착하면 coordinator가 typed reset intent만 메모리에 latch한다. 중복 resume는 기존 deadline을 연장하지 않고, timer가 fire하면 running 상태를 복구한 뒤 wake request를 같은 generation의 quota-reset baseline으로 승격한다. 따라서 child는 하나만 시작하며 reset 신호 유실, wake와 reset의 이중 조회 및 잘못된 burst를 모두 피한다. 명시적 stop과 새 start는 남아 있는 reset intent를 폐기한다.

composition의 `ApplicationActivityReducer`는 sleep과 session lock을 중복 가능한 set으로 유지한다. 첫 중단 사유가 시작될 때만 coordinator에 suspend command를 보내고 마지막 사유가 끝날 때만 resume command를 보낸다. 중복 notification이나 존재하지 않는 사유의 종료는 no-op이므로 wake 뒤에도 여전히 잠긴 session에서 polling이 먼저 재개되지 않는다.

reset 절대 시각과 제품별 24시간 만료는 wall clock `Date`이므로 polling의 단조 deadline으로 변환하지 않는다. `QuotaResetRefreshScheduler`가 clock change, publication 교체와 sleep/wake에 맞춰 별도 one-shot을 재등록하며 이 분리는 polling timer가 wall-clock 변경으로 앞당겨지거나 지연되는 것을 막는다.

## 6. AppKit 생명주기

### 상태 항목

`StatusItemController`는 앱 실행 동안 유지되며 domain `DisplayFrame`을 AppKit 표현으로 바꾸는 얇은 경계다. production의 `SystemStatusItemPresenter`만 `NSStatusItem`을 알고 controller test는 주입한 presenter를 사용해 전역 status bar를 만들지 않는다. 상세 메뉴는 별도 adapter가 메모리 snapshot으로 구성하며 조회 완료를 기다리지 않는다.

`StatusFrameRenderer`는 기존 `DisplayFrameFormatter`의 문자열과 접근성 의미를 그대로 사용한다. bracket token만 작은 단색 rounded-border template image로 치환하고 숫자 영역에는 monospaced digit font를 적용한다. 기간 배지는 label과 effective appearance를 key로 캐시하며 캐시는 작은 고정 상한을 갖는다. 상태 항목에는 별도 앱 아이콘이나 animation을 넣지 않는다.

controller는 각 현재 frame의 제품·기간·비교 구조를 보존하고 모든 quota 값을 `stale(100)`으로 바꾼 최악값 prototype을 순수 변환으로 항상 만든다. 선택되었지만 현재 응답에 없는 대안은 호출자가 별도 prototype으로 더할 수 있다. 실제 frame과 모든 prototype을 한 번 렌더링하고 최대 측정 폭에 12pt를 더해 `NSStatusItem.length`를 고정하며, 최대 문자열을 자르는 임의 상한은 두지 않는다. 여러 frame은 attributed title과 접근성 label까지 미리 렌더링한다. `StatusFrameRotation`은 5초 timer(tolerance 1초)에서 배열 index와 presenter만 갱신하므로 tick에서 formatter, layout 측정 또는 I/O를 호출하지 않는다.

frame이 하나면 scheduler에 timer 생성이나 취소 command를 보내지 않는다. 메뉴 열림, 화면 잠금, sleep, VoiceOver, Reduce Motion은 set으로 중첩 관리한다. 하나라도 활성화되면 timer를 취소하며 모든 사유가 해제되면 frame 0을 즉시 표시하고 새 5초 주기를 시작한다. 중단 중 경과한 tick은 실행하지 않는다.

`AssistiveDisplayMonitor`는 `NSWorkspace`의 accessibility display options 변경 notification과 `isVoiceOverEnabled` KVO만 관찰한다. 시작할 때 VoiceOver와 Reduce Motion의 현재 값을 하나의 immutable `AssistiveDisplayState`로 전달하고, 이후 두 관찰 경계 중 하나가 바뀌면 전체 상태를 다시 읽어 실제 값이 달라진 경우에만 changed event를 보낸다. observer 등록은 idempotent하며 `stop()`은 notification token과 KVO observation을 모두 해제한다.

실제 `NSWorkspace` 접근은 주입 가능한 `AssistiveDisplayStateSourcing` 뒤에 둔다. monitor는 timer, status item, provider 또는 I/O를 소유하지 않으며 typed state callback만 composition root에 제공한다. composition은 두 boolean을 각각 `.voiceOver`와 `.reduceMotion` rotation pause reason으로 연결하되 monitor와 `StatusItemController`를 직접 결합하지 않는다.

상세 메뉴는 `QuotaDetailsMenuInput → QuotaDetailsMenuModel → StatusMenuController`로 분리한다. 순수 builder는 메모리의 제품별 `ProductUsageState`, typed issue와 마지막 성공 시각만 받아 Codex·Spark section, 모든 quota window, 절대 reset 시각과 action group을 만든다. stale, partial과 unavailable은 제품별로 독립 유지하며 값을 알 수 없는 상태를 `0%`로 만들지 않는다. date formatter와 localization value를 주입해 합성 시각으로 검증할 수 있다.

`StatusMenuController`는 상태 갱신 시 완성된 immutable model로 `NSMenu`를 미리 구성하고 `SystemStatusItemPresenter`에 연결한다. menu open callback에서는 model 생성, 날짜 formatting 또는 snapshot 조회를 하지 않고 `.menuOpen` rotation pause만 설정하며 close에서 해제한다. action은 refresh, Codex 열기·선택, 설정과 종료 closure로 주입하므로 UI adapter가 provider, process 또는 설정 창을 직접 알지 않는다. 실제 coordinator와 settings action이 없는 개발 host에는 무동작 메뉴를 붙이지 않고 이후 composition task에서 controller를 보유·연결한다. Spend-control은 현재 `UsageSnapshot`에 보존되지 않으므로 protocol result를 UI에 누출해 표시하지 않고, 별도 cached domain state가 추가되는 task까지 보류한다.

### 설정 창

`CodexGaugeSettings`의 `SettingsFormState`, reducer와 presenter가 표시 제품, 자동·직접 선택, 발견·누락 quota 행, 갱신 프리셋과 로그인 실행 의도를 UI와 무관한 immutable value로 다룬다. AppKit view controller는 이 결과를 programmatic `NSStackView`와 Auto Layout에 투영하고 사용자 event를 reducer로 돌려보내는 얇은 adapter다. 발견한 quota 식별자는 메모리 provider로 주입하며 UI가 provider나 process를 직접 호출하지 않는다.

`SettingsWindowCoordinator`는 창을 요청할 때만 약 440pt 폭의 독립 `NSWindowController`를 만들고 한 번에 하나만 보유한다. 변경된 `SettingsFormValues`는 actor repository에 순서대로 전달하며 repository가 저장 시점의 최신 executable URL과 최초 실행 field에 원자적으로 merge한다. 따라서 창이 열린 동안 다른 owner가 갱신한 숨은 field를 오래된 form state가 덮어쓰지 않는다. 창을 닫은 뒤 다시 열 때는 진행 중인 저장을 먼저 마치고 `UserDefaults`를 새로 읽는다. window close callback은 coordinator의 강한 참조와 AppKit content graph를 제거한다. 로그인 실행 UI는 intent만 저장하며 `SMAppService` 호출은 launch adapter 경계에 남긴다. quota snapshot이나 오류 원문은 저장하지 않는다.

각 form event는 저장 queue와 별도로 주입된 `onSettingsFormValuesChanged` callback에도 전달한다. composition root는 이 seam을 현재 display preference, refresh profile과 로그인 실행 intent에 적용하며 설정 UI가 runtime controller를 직접 알지 않게 한다.

초기 quota 조회가 열린 설정 창보다 늦게 끝나면 composition root는 `updateDiscoveredQuotaIDs(_:)`로 발견 목록만 교체한다. 이 system update는 remembered selection과 form value를 보존하고 UI row만 다시 만들며 저장 queue와 runtime preference callback을 호출하지 않는다. 창이 없을 때는 아무 객체도 만들지 않고 다음 `showSettings()`가 provider의 최신 목록을 읽는다.

연결 영역은 `ConnectionDiagnosticsInspector`가 만든 immutable `ConnectionDiagnosticsSnapshot`만 소비한다. Inspector actor는 locator가 검증한 URL을 내부에서만 사용해 `CodexCLIVersionProbe`를 실행하고, UI에는 자동·사용자 선택 출처, 일반화된 위치 category, 제한된 basename, CLI version token과 typed 상태만 넘긴다. `ConnectionStatusResolver`는 메모리에 있는 `RefreshPublication`의 checking, 마지막 성공과 typed failure를 연결 상태로 바꾸므로 설정을 열기 위해 별도 App Server quota 조회를 만들지 않는다.

`CodexCLIVersionProbe`는 shell 없이 검증된 executable을 `--version` 인자 하나로 실행하는 background actor다. stdin과 stderr는 `/dev/null`에 연결하고 stdout은 한 chunk씩 backpressure를 유지하며 최대 4 KiB까지만 받는다. production child environment는 부모의 `LANG`, `LC_ALL`, `LC_CTYPE` 중 존재하는 값만 새 dictionary에 복사하고 `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`을 항상 설정한다. 이 고정 순서는 system interpreter를 Homebrew·Intel Homebrew 위치보다 먼저 찾으면서 `#!/usr/bin/env …` wrapper도 지원한다. 부모의 `PATH`, `HOME`과 그 밖의 environment는 전달하지 않는다.

nvm, asdf와 Volta처럼 사용자 home 아래의 runtime manager path 탐색은 v0.1의 비목표다. 해당 runtime에만 의존하는 wrapper는 사용자가 executable로 선택해도 version probe가 `processFailed`가 될 수 있으며, 이를 해결하기 위해 interactive shell이나 부모 PATH를 실행 경계로 가져오지 않는다.

Parser는 선택적인 마지막 LF 또는 CRLF를 제외한 전체 출력이 정확히 `codex-cli <version>` 또는 `codex <version>` 한 줄인지 확인한다. version은 숫자 세 component와 선택적인 점 구분 prerelease·build identifier로 구성되고 최대 64자다. 따라서 출력의 다른 위치에서 그럴듯한 숫자를 찾거나 account 문구, 추가 숫자, 빈 component와 여러 줄을 허용하지 않는다. 원문 stdout, exit 설명과 경로는 보존하지 않는다.

Probe는 2초 timeout과 제한된 terminate/SIGKILL grace로 자신이 직접 시작한 child를 정리한다. Foundation `Process`가 direct child PID만 소유하는 경계에서 별도 process group을 만들거나 임의의 descendant tree를 추적·종료하는 것은 v0.1의 비목표다. version command가 descendant를 만드는 executable은 지원 대상으로 가정하지 않는다.

`SettingsFormViewController`의 `Codex 선택…`과 `진단 정보 복사`는 closure로 주입된다. 실제 `NSOpenPanel`과 `NSPasteboard` 접근은 각각 `NSOpenPanelCodexExecutableSelector`, `SystemDiagnosticClipboardWriter`에만 있다. 메뉴의 선택 action도 public `requestExecutableSelection()`을 호출해 필요하면 설정 창을 먼저 열고 같은 panel·저장 경로를 재사용한다. 선택 URL 저장은 repository actor가 최신 form·최초 실행 값을 보존하며 merge하고 외부 executable-selection callback이 provider 재구성을 요청할 수 있다. 선택 task는 generation으로 식별해 닫힌 창의 늦은 결과가 새 panel task를 지우지 못하게 하며, 저장을 시작한 선택은 창이 닫혀도 runtime callback까지 완료한다. pending selection은 window controller를 강하게 보유하지 않는다. 창 close는 진행 중 diagnostics task를 generation과 cancellation로 무효화하고, 다음 진단은 이전 CLI process cleanup task의 완료를 기다린 뒤 시작한다.

window controller와 view controller가 실제로 해제되는지는 weak-reference 단위 테스트로 검증한다.

### 로그인 시 실행

`LaunchAtLoginController`는 main actor에서 `SMAppService.mainApp`을 감싸고 `disabled`, `enabled`, `requiresApproval`, `unavailable`의 비식별 상태만 UI에 제공한다. 이미 원하는 상태에서는 register 또는 unregister를 반복하지 않는다. 승인 대기 상태에서 enable 요청은 재등록하지 않고 로그인 항목 System Settings 동작을 별도로 제공하며, disable 요청은 등록을 해제한다.

macOS 호출이 실패해도 호출 직후 시스템 상태가 이미 요청 결과가 되었다면 경쟁 상태의 성공으로 취급한다. 그 밖의 NSError domain, code와 description은 버리고 registration, unregistration, unavailable의 typed failure만 전달한다. 설정의 `launchAtLoginIntent`는 사용자가 마지막으로 요청한 값이며 실제 토글 상태와 복구 안내는 매번 `SMAppService` 상태를 기준으로 구성한다.

### 최초 실행

상태 항목과 초기 조회를 먼저 시작한 뒤 `hasCompletedFirstLaunch`가 false이면 설정 창을 연다. 창 표시가 성공한 뒤 `markFirstLaunchCompleted()`로 플래그를 기록한다. 이 actor 연산은 저장 시점의 표시·refresh·로그인·선택 executable 값을 모두 보존하고 최초 실행 값만 true로 바꾸며, 이미 완료된 경우에는 다시 쓰지 않는다. UI 테스트 launch argument는 테스트 전용 defaults domain을 사용한다.

## 7. 설정 저장

`CodexGaugeSettings`의 `AppPreferences`는 다음과 같은 비밀이 아닌 값만 가진 immutable `Sendable` value다.

- 표시 제품
- 자동 또는 직접 한도 식별자
- 갱신 프리셋
- 로그인 시 실행 의도
- 사용자가 선택한 Codex 실행 파일 경로
- 최초 실행 완료 여부

`AppPreferencesRepository` actor만 주입받은 `UserDefaults`에 접근한다. 전체 값을 `io.github.symflee.codex-gauge.preferences`라는 하나의 namespaced key에 versioned JSON `Data`로 저장해 같은 defaults domain의 다른 key를 건드리지 않는다. 일반적인 전체 `load`·`save` 외에 설정 form, 선택 executable과 최초 실행 완료 저장은 각각 담당 field만 받아 최신 전체 값에 actor 내부에서 read-modify-write한다. 세 연산에는 suspension point가 없어 동시 호출도 직렬화되며 서로의 최신 값을 잃지 않는다. 최초 실행 완료 저장은 true에서 no-op인 단방향·멱등 연산이다.

저장 envelope에는 schema version을 별도로 포함한다. 현재 version 1은 display 설정을 중첩하고 나머지 허용 필드를 top-level에 둔다. version 0은 `displayProductMode`, `displayQuotaSelection`, `manualQuotaSelections`가 분리된 초기 flat schema이며 순수 decoder에서 현재 `AppPreferences`로 migration한다. manual selection은 제품 raw value 오름차순, 같은 제품 안에서는 양수 raw duration 오름차순과 기간 미상 마지막 순서로 정렬해 항상 같은 byte를 만든다. 빈 manual selection은 automatic으로 정규화한다.

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
