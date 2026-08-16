# Codex App Server 프로토콜 경계

## 1. 사용 목적

Codex Gauge는 설치된 Codex가 제공하는 App Server를 별도 child process로 실행하고 JSONL RPC로 남은 사용 한도를 읽는다. 기준은 공식 [Codex App Server 문서](https://developers.openai.com/codex/app-server)다.

App Server 인터페이스는 experimental이므로 이 문서는 특정 버전의 wire schema를 앱 전체에 확산시키지 않기 위한 compatibility boundary다. 실제 구현 시 설치된 CLI의 schema와 공식 문서를 함께 검증하고 합성 fixture를 갱신한다.

## 2. 허용하는 method

v0.1은 다음 흐름만 사용한다.

1. `initialize`
2. `initialized`
3. `account/read` (`refreshToken: false`)
4. `account/rateLimits/read`

`account/read`는 session의 첫 quota 조회에서 한 번만 실행한다. `chatgpt` 계열 또는 미래의 unknown provider를 확인하면 비식별 boolean 상태만 session 메모리에 남기고, 같은 child를 재사용하는 후속 burst 조회에서는 `account/rateLimits/read`만 반복한다. child를 종료하고 새 session을 만들면 account를 다시 확인한다.

`account/read`에서는 account provider type과 `requiresOpenaiAuth`만 즉시 비식별 상태로 분류한다. account의 이메일, plan 문자열과 그 밖의 개인 필드는 account 전용 model이나 앱 상태로 옮기지 않는다. API key와 Bedrock provider는 ChatGPT quota 미지원으로 분류하고, 미래의 알 수 없는 provider는 rate-limit 조회를 시도할 수 있는 unknown 상태로 보존한다.

`account/rateLimits/updated` notification을 수신할 수는 있지만 외부 Codex 사용이 항상 기존 child에 전달된다고 가정하지 않는다. notification은 갱신 힌트로만 사용하고 polling 정책을 제거하지 않는다.

다음 데이터는 상태바 퍼센트 계산에 사용하지 않는다.

- `account/usage/read` token 활동 통계
- thread context token usage
- API key의 RPM·TPM limit
- credits balance와 reset-credit 수
- `individualLimit` spend-control

`individualLimit`와 `spendControlReached`는 존재할 경우 메뉴의 별도 제한 정보로만 표시한다. 설치된 CLI가 생성한 version-specific schema에서 `individualLimit.remainingPercent`는 정수이고 `spendControlReached`는 nullable boolean이다. credits와 reset-credit는 typed 결과로 옮기지 않는다.

## 3. 전송 방식

- executable을 shell 없이 직접 실행한다.
- request와 response는 UTF-8 JSON 한 개를 한 줄에 기록한다.
- request ID는 session 내에서 단조 증가하며 matching ID 응답만 소비한다.
- stdout의 알 수 없는 notification과 field는 무시한다.
- stdout은 한 chunk씩 actor가 처리한 뒤 다음 read를 허용해 무한 buffering 없이 pipe backpressure를 사용한다.
- JSONL은 chunk 경계, 한 chunk의 여러 줄, CRLF, 빈 줄과 마지막 newline이 없는 EOF를 처리한다.
- 한 JSON line은 UTF-8 byte 기준 1 MiB로 제한한다.
- stderr는 null device로 직접 버려 deadlock을 피하고 원문을 메모리 value나 사용자 로그로 옮기지 않는다.
- EOF, timeout, JSON 파싱 실패와 method-not-found를 서로 다른 typed failure로 바꾼다.
- JSON-RPC error에서는 정수 `code`만 보존하고 원문 `message`와 `data`는 앱의 value type으로 옮기지 않는다.

initialize timeout은 5초, account와 rate-limit request timeout은 각각 15초다. request마다 waiter는 하나이고 timeout, task cancellation, EOF, 명시적 stop 중 먼저 확정된 사건만 continuation을 완료한다. 늦게 도착한 사건과 mismatched response는 이미 완료된 결과를 바꾸지 않는다.

stdout callback은 read 가능한 chunk를 하나 가져온 직후 handler를 잠시 해제한다. actor가 해당 chunk의 1 MiB framing과 모든 line 분류를 끝내야 handler를 다시 연결하므로, server가 notification을 빠르게 보내도 앱 내부에 무제한 `AsyncStream` 또는 배열이 쌓이지 않는다. 이는 chunk를 drop하고 정상 응답을 계속하는 방식이 아니라 OS pipe의 bounded backpressure를 사용하는 방식이다.

### 실행 파일 탐색

App Server session을 열기 전에 `CodexLocating`에서 검증된 executable URL을 받는다.

1. 저장된 사용자 선택이 있으면 그 URL만 검사한다.
2. 선택이 없으면 `com.openai.codex`용 adapter가 주입한 app bundle의 `Contents/Resources/codex`를 검사한다.
3. 이후 macOS application resource, Apple Silicon·Intel Homebrew 위치와 주입된 home의 local CLI 후보를 순서대로 검사한다.

사용자 선택이 invalid 또는 broken symlink이면 자동 후보가 있더라도 `invalidSelection`이다. 자동 후보가 모두 유효하지 않으면 `notFound`다. 두 오류에는 원문 path를 associated value나 description으로 넣지 않는다.

탐색은 Foundation filesystem API만 사용한다. file URL, 존재 여부, directory 여부, symlink 최종 target의 regular-file type과 executable permission을 검증한다. symlink cycle과 broken target은 거부하며 PATH, shell, CLI version 실행, 실제 process 시작은 이 단계에서 수행하지 않는다. 단위 테스트는 주입된 합성 home·system root만 사용하고 실제 machine 설치를 smoke test하지 않는다.

### CLI 버전 진단

실행 파일 탐색이 성공하면 설정 연결 영역의 별도 `CodexCLIVersionProbe` actor가 같은 검증 URL을 shell 없이 `--version` 인자 하나로 실행할 수 있다. 이는 App Server handshake나 quota 조회가 아니며 account, 인증 또는 raw JSON을 다루지 않는다.

- timeout: 2초
- stdout 상한: UTF-8 4 KiB
- 허용 출력: `codex-cli <version>` 또는 `codex <version>` 한 줄과 선택적인 마지막 LF·CRLF
- 표시 value: 숫자 세 component와 선택적인 prerelease·build identifier로 이루어진 최대 64자 version
- stdin: `/dev/null`
- stderr: null device로 폐기
- environment: 고정 safe PATH와 부모의 `LANG`, `LC_ALL`, `LC_CTYPE` 중 존재하는 값만 복사
- 종료: 제한된 250ms grace 뒤 필요 시 SIGKILL
- 공개 오류: launch, timeout, process, output-too-large, invalid-output, cancelled

production의 safe PATH는 `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`으로 고정하며 system directory가 먼저다. 이는 직접 선택한 executable 자체를 찾기 위한 PATH가 아니라 그 executable이 `#!/usr/bin/env node` 같은 wrapper일 때 알려진 system·Homebrew interpreter를 찾기 위한 것이다. 부모 `PATH`, `HOME`, 인증·token을 포함할 수 있는 다른 parent environment는 전달하지 않는다. nvm, asdf와 Volta의 사용자별 runtime directory 탐색은 비목표이며 이를 위해 shell profile을 읽지 않는다.

Parser는 출력에서 첫 번째 version처럼 보이는 token을 검색하지 않으며 account 문구, 추가 숫자·공백, `1..2` 같은 빈 component와 여러 줄이 있으면 전체를 거부한다. 현재 알려진 `codex-cli 0.148.0-alpha.9` 형태는 허용한다.

stdout 원문과 exit 설명은 value, UI, clipboard 또는 로그에 남기지 않는다. 설정의 연결 상태는 이 probe만으로 로그인 성공을 추측하지 않고 기존 refresh publication의 typed 상태를 우선 사용한다. timeout과 cancellation은 기존처럼 직접 child에 TERM을 보내고 grace 뒤에도 실행 중이면 해당 PID에 KILL을 보낸다. Foundation `Process`가 직접 child만 추적하므로 별도 process group 구성과 descendant tree 종료는 이 probe의 비목표이며, version command가 descendant를 만들지 않는다는 계약에 의존한다.

## 4. 합성 예제

아래 값은 문서 설명을 위한 가상 데이터다. 실제 계정, 시각, 퍼센트 또는 응답을 복사한 것이 아니다. App Server 버전에 따라 initialize parameter와 응답의 부가 field가 달라질 수 있다.

### 초기화 요청

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-gauge","title":"Codex Gauge","version":"0.1.0"}}}
```

### 초기화 완료 notification

```json
{"method":"initialized","params":{}}
```

### 계정 상태 조회

```json
{"id":2,"method":"account/read","params":{"refreshToken":false}}
```

```json
{
  "id": 2,
  "result": {
    "account": {
      "type": "chatgpt",
      "planType": "synthetic"
    },
    "requiresOpenaiAuth": true
  }
}
```

위 예제에는 의도적으로 이메일 field가 없다. Decoder가 외부에 제공하는 결과도 `rateLimitsAvailable`, `signedOut`, `unsupportedProvider`, `unknownProvider` 중 하나뿐이다.

### 한도 조회 요청

```json
{"id":3,"method":"account/rateLimits/read","params":{}}
```

### 한도 조회 응답

```json
{
  "id": 3,
  "result": {
    "rateLimits": {
      "primary": {
        "usedPercent": 17,
        "windowDurationMins": 300,
        "resetsAt": 1893456000
      },
      "secondary": {
        "usedPercent": 41,
        "windowDurationMins": 10080,
        "resetsAt": 1893974400
      }
    },
    "rateLimitsByLimitId": {
      "codex": {
        "primary": {
          "usedPercent": 17,
          "windowDurationMins": 300,
          "resetsAt": 1893456000
        },
        "individualLimit": {
          "remainingPercent": 64,
          "limit": "synthetic",
          "used": "synthetic",
          "resetsAt": 1893456000
        },
        "spendControlReached": false
      },
      "codex_bengalfox": {
        "primary": {
          "usedPercent": 9,
          "windowDurationMins": 300,
          "resetsAt": 1893456000
        }
      }
    }
  }
}
```

`resetsAt` 예제는 미래의 가상 epoch다. 테스트에서는 wall clock을 주입하고 고정된 synthetic 시각만 사용한다.

같은 session의 두 번째 한도 조회 request ID는 이어서 증가하지만 `account/read`를 반복하지 않는다.

```json
{"id":4,"method":"account/rateLimits/read","params":{}}
```

## 5. 제품 매핑

| App Server key | 도메인 제품 | 비고 |
| --- | --- | --- |
| `codex` | Codex | 기본 일반 Codex quota |
| `codex_bengalfox` | Spark | 표시 이름과 무관하게 wire key로 식별 |
| top-level `rateLimits` | Codex fallback | multi-limit map이 없는 구버전 대응 |

`rateLimitsByLimitId`가 object로 존재하면 해당 map만 사용한다. 그 map에 Codex key가 없더라도 top-level 값을 대신 사용하지 않는다. top-level `rateLimits`는 multi-limit map이 없거나 `null`인 응답에서만 Codex fallback으로 사용한다. Spark를 top-level 값으로 추측하지 않는다.

각 제품 결과는 독립적으로 다음 상태 중 하나가 된다.

- `available`: 하나 이상의 정상 window가 있고 malformed window가 없음
- `partial`: 정상 window와 malformed window가 함께 있음
- `unavailable`: bucket 또는 모든 window가 없거나 `null`
- `malformed`: bucket이 잘못되었거나 정상 window 없이 malformed window만 있음

multi-limit map 자체가 object가 아니면 두 제품을 malformed로 분류하고 response status도 `incompatible`로 표시하며 legacy 값으로 우회하지 않는다. legacy `rateLimits`를 사용할 때도 해당 container 자체가 object가 아니면 같은 상태다. container가 없거나 빈 object인 응답은 정상적인 empty quota로 받아들인다. 한 제품이나 window의 malformed payload는 outer response를 비호환으로 승격하지 않고 다른 제품 또는 sibling window의 성공값을 보존한다.

## 6. quota 변환

각 primary와 secondary를 독립 `QuotaWindow`로 변환한다.

```text
boundedUsed = min(max(usedPercent, 0), 100)
remaining = 100 - boundedUsed
```

- 유효한 값이 100 이상일 때만 남은 값을 `0%`로 표시한다.
- 음수와 100 초과 값은 UI 안전을 위해 경계 안으로 보정하고 비식별 진단 code를 남긴다.
- field 누락은 `0`으로 기본화하지 않고 해당 window의 부분 실패로 처리한다.
- `usedPercent`는 정수와 부동소수 JSON number를 모두 받는다.
- duration과 reset은 누락 또는 `null`일 수 있지만 잘못된 type은 해당 window의 malformed 결과다.
- unknown field는 무시한다.
- 알 수 없는 limit ID는 v0.1 표시 대상에서 제외하되 전체 decoding은 실패시키지 않는다.
- duration이 없으면 `?`로 나타내고 월간 의미를 추측하지 않는다.

Spend-control은 quota window와 별도로 최소 정보만 변환한다.

- `individualLimit.remainingPercent`가 유한한 JSON number이면 `0...100`으로 clamp한 뒤 내림한다.
- `spendControlReached`가 boolean이면 그대로 보존한다.
- 두 field 중 해석 가능한 정보가 하나라도 있을 때만 `SpendControlLimit`를 만든다.
- remaining percent가 없거나 잘못되면 `nil`, reached가 없으면 `nil`로 유지해 상태를 추측하지 않는다.
- malformed spend-control은 제품의 quota `available/partial` 상태를 바꾸지 않는다.
- `limit`, `used`, spend reset 시각, credits와 reset-credit 세부정보는 버린다.

## 7. 호환성과 오류 분류

| protocol 결과 | 앱 상태 |
| --- | --- |
| 정상 응답 | 제품별 snapshot 갱신 |
| 정상 empty quota | 값 성공 시각은 유지하고 연결 성공 시각만 갱신 |
| quota container가 object가 아님 | terminal incompatible protocol |
| 한 제품만 malformed | 해당 제품만 stale/unavailable |
| request timeout | transient timeout 및 backoff |
| child EOF 또는 비정상 종료 | transient process failure |
| method-not-found | unsupported Codex version |
| initialize 실패 | incompatible protocol |
| 인증되지 않은 account 상태 | logged out |
| executable 없음 | Codex not found |

Session adapter의 공개 오류는 lifecycle용 `notStarted`·`requestInProgress`·`requestIdentifierExhausted`, `launchFailed`, optional exit status만 가진 `processFailed`, `endOfFile`, operation별 `timeout`, `malformedResponse`, `responseTooLarge`, `unsupportedVersion`, `signedOut`, `unsupportedAuth`, code만 가진 `rpcFailure`, `stopped`, `cancelled`를 구분한다. 원문 stderr, JSON-RPC message/data, 이메일과 executable path는 오류 associated value에 넣지 않는다.

정상 session은 소유자가 명시적으로 `stop()`한다. stop은 stdin을 닫고 제한된 grace 동안 비동기로 종료를 관찰한 뒤 필요하면 SIGKILL하며 blocking `waitUntilExit`를 사용하지 않는다. Failed session은 호출자가 stop을 누락해도 같은 bounded cleanup을 자동 실행한다.

성공 snapshot이 있으면 transient 실패 동안 24시간 또는 reset 시각까지 `~`로 유지한다. 둘 중 먼저 도달한 시점 이후에는 `—`로 바꾼다. reset 시각이 지났다고 100%로 추측하지 않는다.

Decoder fixture에는 다음을 포함한다.

- initialize result와 JSON-RPC result/error/notification/request 분류
- account의 로그인, 미지원 provider와 미래 provider 분류
- Codex와 Spark가 모두 존재하는 응답
- top-level Codex fallback
- primary와 secondary
- 제품·window별 부분 누락과 독립 malformed
- unknown field와 unknown limit ID
- malformed JSON과 잘못된 field type
- used percent 경계값
- duration과 reset 시각 누락
- 정상·malformed spend-control, remaining percent 내림과 clamp
- split chunk, 여러 줄, CRLF, 빈 줄과 newline 없는 EOF
- 정확히 1 MiB인 line과 상한 초과 line
- 실제 합성 child의 handshake, account 1회 cache와 연속 rate-limit request ID
- 실제 합성 `--version` child의 정상·malformed·oversized·nonzero·timeout·stderr flood
- version 전체 한 줄 shape, 실제 alpha version, 추가 account·숫자와 빈 component 거부
- version child의 stdin EOF, 고정 safe PATH exact value와 그 밖의 parent environment 제거
- 합성 `/usr/bin/env` wrapper의 주입 safe PATH interpreter lookup
- notification·server request·mismatched ID, timeout·cancellation·EOF·nonzero exit
- stderr flood와 stdout notification flood의 deadlock·unbounded-buffer 방지
- stop과 failed-path cleanup 뒤 orphan process 부재

모든 fixture는 가상 값만 사용한다.

## 8. 금지 경계

- 인증 파일 직접 읽기
- access token 추출 또는 갱신
- 웹 사용량 페이지 scraping
- CLI의 사람이 읽는 `/status` 출력 parsing
- Codex 앱의 private IPC, SQLite 또는 세션 로그 사용
- raw JSONL, stderr, 이메일 또는 token을 파일이나 `OSLog`에 기록
- 사용자 모르게 다른 HTTP endpoint 호출

공식 protocol 변경으로 이 경계를 넘어야 할 경우 구현 전에 product/security 결정을 다시 기록한다.
