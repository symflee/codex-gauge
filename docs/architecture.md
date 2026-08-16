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
- UI와 timer는 main actor, blocking I/O는 main actor 밖에서 실행

## 2. 데이터 흐름

```text
Codex executable
      │ JSONL over stdin/stdout
      ▼
CodexUsageProviding / UsageSession
      │ UsageSnapshot or typed failure
      ▼
RefreshCoordinator
      │ current UsageState
      ▼
DisplayFrame builder
      │ cached visual and accessibility content
      ▼
StatusItemController / menu / settings
```

UI adapter는 provider를 직접 호출하지 않는다. 모든 조회는 `RefreshCoordinator`를 통해 직렬화하고, UI는 이미 해석된 snapshot과 상태만 소비한다.

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

### `UsageState`

`loading`, `fresh`, `stale`, `unavailable`을 구분한다. 오류의 종류는 typed reason으로 유지하고 표시 단계에서 현지화된 메시지로 바꾼다.

## 4. 외부 프로세스 경계

### `CodexLocating`

실행 파일은 다음 순서로 찾는다.

1. 사용자가 명시적으로 선택해 저장한 유효 실행 파일
2. `NSWorkspace`가 bundle ID `com.openai.codex`로 찾은 앱의 `Contents/Resources/codex`
3. 지원 목록에 명시된 Homebrew·CLI 설치 위치
4. 찾지 못하면 typed `notFound` 실패

Finder로 실행한 앱은 사용자의 interactive shell `PATH`를 신뢰할 수 없으므로 PATH만으로 탐색하지 않는다. 사용자 선택 경로는 regular executable file인지 다시 확인한다.

### `CodexUsageProviding`과 `UsageSession`

Provider는 session 생성만 책임지고 session은 다음을 캡슐화한다.

- `Process` 시작과 종료
- stdin/stdout JSONL framing
- request ID 생성과 응답 matching
- `initialize` handshake
- `account/rateLimits/read`
- timeout, EOF, malformed response와 unsupported method 분류

shell을 거치지 않고 실행 파일 URL을 `Process`에 직접 전달한다. stdout line parser와 stderr drain은 main actor 밖에서 동작한다. 종료 순서는 stdin close, 제한된 graceful wait, 필요 시 child terminate이며 orphan process를 남기지 않는다.

## 5. 갱신 상태 머신

`RefreshCoordinator`는 timer, 수동 요청, reset 요청, 시스템 상태를 하나의 actor에서 직렬화한다.

### 평상시

- 프리셋의 평상시 간격에 맞춰 session을 시작한다.
- snapshot을 받은 뒤 증가가 없으면 session을 종료한다.
- timer, 메뉴의 수동 갱신, wake와 reset 요청이 겹치면 하나의 in-flight 작업으로 합친다.

### burst

- 같은 reset cycle의 선택 quota에서 정수 used percent 증가가 감지되면 현재 session을 유지한다.
- 프리셋의 burst 간격으로 최대 5분간 재조회한다.
- 추가 증가 시 종료 deadline을 5분 연장한다.
- deadline 도달 또는 연속 3회 실패 시 session을 종료한다.

### backoff

일시 실패는 30초, 1분, 2분, 4분, 8분, 16분, 30분 순으로 지수 backoff한다. 성공하면 실패 횟수를 지우고 사용자가 선택한 프리셋으로 돌아간다. 로그아웃, 실행 파일 미발견과 protocol 비호환은 무한 재시도하지 않고 사용자 조치 상태로 전환한다.

### 시스템 상태

- sleep 또는 화면 잠금 알림을 받으면 timer와 child를 종료한다.
- wake 또는 unlock 후 5초 뒤 단발 조회한다.
- sleep 중 놓친 tick을 연속 실행하지 않는다.
- wake 조회에서 이전 값보다 증가했더라도 이를 burst 신호로 사용하지 않는다.
- Low Power Mode에서는 평상시 10분, burst 60초보다 빠르게 실행하지 않는다.

## 6. AppKit 생명주기

### 상태 항목

`StatusItemController`는 앱 실행 동안 유지된다. `NSStatusItem`과 메뉴를 소유하고 현재 frame을 보여준다. menu opening 시 메모리 snapshot으로 항목을 새로 구성하지만 조회 완료를 기다리지 않는다.

기간 배지는 label과 light/dark appearance를 key로 캐시한다. 캐시는 작은 고정 상한을 갖고 label이 바뀔 때만 렌더링한다.

### 설정 창

앱 delegate는 설정 controller를 강하게 영구 보유하지 않는다. 설정을 열 때 controller를 만들고, window close callback에서 참조를 제거한다. 설정 값은 변경 시 `UserDefaults`에 저장한다. quota snapshot이나 오류 원문은 저장하지 않는다.

window controller와 view controller가 실제로 해제되는지는 weak-reference 단위 테스트로 검증한다.

### 최초 실행

상태 항목과 초기 조회를 먼저 시작한 뒤 `hasCompletedFirstLaunch`가 false이면 설정 창을 연다. 창 표시가 성공한 뒤 플래그를 기록한다. UI 테스트 launch argument는 테스트 전용 defaults domain을 사용한다.

## 7. 설정 저장

`UserDefaults`에는 다음과 같은 비밀이 아닌 preference만 저장한다.

- schema version
- 표시 제품
- 자동 또는 직접 한도 식별자
- 갱신 프리셋
- 로그인 시 실행 의도
- 사용자가 선택한 Codex 실행 파일 경로
- 최초 실행 완료 여부

저장 구조는 versioned value로 감싸고 알 수 없는 enum 값은 안전한 기본값으로 복구한다. migration은 순수 함수로 구현하고 fixture로 테스트한다.

## 8. 보안과 개인정보 경계

- Codex 인증 파일과 브라우저 cookie를 읽지 않는다.
- token, 이메일, raw JSONL, 세션 로그와 quota history를 저장하지 않는다.
- stderr는 pipe deadlock을 방지하기 위해 소비하되 민감정보가 제거되지 않은 채 `OSLog`에 쓰지 않는다.
- 진단 정보에는 앱 버전, macOS 버전, 선택 경로의 유효 여부, CLI 버전, 마지막 typed error code만 포함한다.
- 사용자 경로는 진단 복사 시 basename 또는 일반화된 위치로 축약한다.
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
