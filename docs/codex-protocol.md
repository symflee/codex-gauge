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
- JSONL은 chunk 경계, 한 chunk의 여러 줄, CRLF, 빈 줄과 마지막 newline이 없는 EOF를 처리한다.
- 한 JSON line은 UTF-8 byte 기준 1 MiB로 제한한다.
- stderr는 deadlock 방지를 위해 drain하지만 원문을 사용자 로그에 기록하지 않는다.
- EOF, timeout, JSON 파싱 실패와 method-not-found를 서로 다른 typed failure로 바꾼다.
- JSON-RPC error에서는 정수 `code`만 보존하고 원문 `message`와 `data`는 앱의 value type으로 옮기지 않는다.

### 실행 파일 탐색

App Server session을 열기 전에 `CodexLocating`에서 검증된 executable URL을 받는다.

1. 저장된 사용자 선택이 있으면 그 URL만 검사한다.
2. 선택이 없으면 `com.openai.codex`용 adapter가 주입한 app bundle의 `Contents/Resources/codex`를 검사한다.
3. 이후 macOS application resource, Apple Silicon·Intel Homebrew 위치와 주입된 home의 local CLI 후보를 순서대로 검사한다.

사용자 선택이 invalid 또는 broken symlink이면 자동 후보가 있더라도 `invalidSelection`이다. 자동 후보가 모두 유효하지 않으면 `notFound`다. 두 오류에는 원문 path를 associated value나 description으로 넣지 않는다.

탐색은 Foundation filesystem API만 사용한다. file URL, 존재 여부, directory 여부, symlink 최종 target의 regular-file type과 executable permission을 검증한다. symlink cycle과 broken target은 거부하며 PATH, shell, CLI version 실행, 실제 process 시작은 이 단계에서 수행하지 않는다. 단위 테스트는 주입된 합성 home·system root만 사용하고 실제 machine 설치를 smoke test하지 않는다.

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

multi-limit map 자체가 object가 아니면 두 제품을 malformed로 분류하고 legacy 값으로 우회하지 않는다. 한 제품이나 window의 malformed payload가 다른 제품 또는 sibling window의 성공값을 폐기하게 하지 않는다.

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
| 한 제품만 malformed | 해당 제품만 stale/unavailable |
| request timeout | transient timeout 및 backoff |
| child EOF 또는 비정상 종료 | transient process failure |
| method-not-found | unsupported Codex version |
| initialize 실패 | incompatible protocol |
| 인증되지 않은 account 상태 | logged out |
| executable 없음 | Codex not found |

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
