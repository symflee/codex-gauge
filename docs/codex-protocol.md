# Codex App Server 프로토콜 경계

## 1. 사용 목적

Codex Gauge는 설치된 Codex가 제공하는 App Server를 별도 child process로 실행하고 JSONL RPC로 남은 사용 한도를 읽는다. 기준은 공식 [Codex App Server 문서](https://developers.openai.com/codex/app-server)다.

App Server 인터페이스는 experimental이므로 이 문서는 특정 버전의 wire schema를 앱 전체에 확산시키지 않기 위한 compatibility boundary다. 실제 구현 시 설치된 CLI의 schema와 공식 문서를 함께 검증하고 합성 fixture를 갱신한다.

## 2. 허용하는 method

v0.1은 다음 흐름만 사용한다.

1. `initialize`
2. `initialized`
3. `account/rateLimits/read`

`account/rateLimits/updated` notification을 수신할 수는 있지만 외부 Codex 사용이 항상 기존 child에 전달된다고 가정하지 않는다. notification은 갱신 힌트로만 사용하고 polling 정책을 제거하지 않는다.

다음 데이터는 상태바 퍼센트 계산에 사용하지 않는다.

- `account/usage/read` token 활동 통계
- thread context token usage
- API key의 RPM·TPM limit
- credits balance와 reset-credit 수
- `individualLimit` spend-control

`individualLimit`나 rate-limit reached 상태는 존재할 경우 메뉴의 별도 제한 정보로만 표시한다.

## 3. 전송 방식

- executable을 shell 없이 직접 실행한다.
- request와 response는 UTF-8 JSON 한 개를 한 줄에 기록한다.
- request ID는 session 내에서 단조 증가하며 matching ID 응답만 소비한다.
- stdout의 알 수 없는 notification과 field는 무시한다.
- stderr는 deadlock 방지를 위해 drain하지만 원문을 사용자 로그에 기록하지 않는다.
- EOF, timeout, JSON 파싱 실패와 method-not-found를 서로 다른 typed failure로 바꾼다.

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

### 한도 조회 요청

```json
{"id":2,"method":"account/rateLimits/read","params":{}}
```

### 한도 조회 응답

```json
{
  "id": 2,
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
        }
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

`rateLimitsByLimitId`가 있으면 해당 map을 우선한다. Codex key가 없고 top-level `rateLimits`만 유효하면 Codex로 사용한다. Spark를 top-level 값으로 추측하지 않는다. 한 제품의 malformed payload가 다른 제품의 성공값을 폐기하게 하지 않는다.

## 6. quota 변환

각 primary와 secondary를 독립 `QuotaWindow`로 변환한다.

```text
boundedUsed = min(max(usedPercent, 0), 100)
remaining = 100 - boundedUsed
```

- 유효한 값이 100 이상일 때만 남은 값을 `0%`로 표시한다.
- 음수와 100 초과 값은 UI 안전을 위해 경계 안으로 보정하고 비식별 진단 code를 남긴다.
- field 누락은 `0`으로 기본화하지 않고 해당 window의 부분 실패로 처리한다.
- unknown field는 무시한다.
- 알 수 없는 limit ID는 v0.1 표시 대상에서 제외하되 전체 decoding은 실패시키지 않는다.
- duration이 없으면 `?`로 나타내고 월간 의미를 추측하지 않는다.

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

- Codex와 Spark가 모두 존재하는 응답
- top-level Codex fallback
- primary와 secondary
- 제품별 부분 누락
- unknown field와 unknown limit ID
- malformed JSON과 잘못된 field type
- used percent 경계값
- duration과 reset 시각 누락

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
