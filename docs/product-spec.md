# Codex Gauge 제품 사양

## 1. 제품 원칙

Codex Gauge는 Codex 사용 한도를 확인하기 위해 작업 흐름을 끊지 않도록 하는 macOS 메뉴 막대 앱이다. 정확한 최신값과 낮은 자원 사용 사이에서 다음 원칙을 지킨다.

- 사용자가 가장 자주 보는 정보는 한눈에 읽을 수 있어야 한다.
- 오류와 `0%`를 혼동시키지 않는다.
- 서버가 주지 않은 기간 의미를 추측하지 않는다.
- 화면에 보이지 않는 기능은 가능한 한 실행하거나 메모리에 유지하지 않는다.
- 인증과 계정 데이터는 설치된 Codex의 경계 밖으로 복제하지 않는다.

## 2. 상태 항목

### 2.1 기간 배지

`windowDurationMins`를 다음과 같이 표현한다.

| 분 | 배지 | 접근성 표현 |
| ---: | --- | --- |
| 300 | `5h` | 5시간 |
| 1,440 | `d` | 1일 |
| 10,080 | `w` | 1주 |
| 20,160 | `2w` | 2주 |
| 43,200 | `30d` | 30일 |
| 없음 또는 알 수 없음 | `?` | 기간 미상 |

`m`은 minute와 month가 혼동되므로 사용하지 않는다. 43,200분도 달력 월간으로 추측하지 않고 `30d`로 표시한다. 알려진 값 이외의 양수 duration은 시간 또는 일 단위의 정확한 길이로 표시하고, 의미 이름을 붙이지 않는다.

### 2.2 표시 문자열

- Codex: `[5h] 83%`
- Spark: `S[5h] 91%`
- 동일 기간의 두 제품: `[w] C75% · S82%`
- 서로 다른 기간의 두 제품: `C[5h]75% · S[w]82%`
- 마지막 성공값: `[5h] ~83%`
- 첫 조회: `[5h] …`
- 조회 불가: `[5h] —`

`~`는 stale 값을 의미한다. 신뢰할 수 없는 상태를 `0%`로 변환하지 않으며 유효한 quota의 `usedPercent`가 100 이상일 때만 `0%`를 표시한다. 100 미만의 소수 사용률에서 계산한 남은 값이 1%보다 작더라도 정수 상태바에는 최소 `1%`로 표시한다.

배지는 단색의 작은 테두리 이미지로 렌더링하고 label·appearance 조합별로 상한이 있는 캐시에 보관한다. 숫자는 monospaced digit을 사용한다. 상태 항목 폭은 현재 표시 모드의 각 frame에서 내부적으로 만든 `~100%` prototype과 실제 frame 중 가장 넓은 결과에 12pt 여백을 더해 고정한다. 최대 문자열을 자르는 임의 폭 상한을 두지 않는다. 값 변경과 순환 때문에 이웃 아이콘이 움직이지 않게 하며 별도 앱 아이콘은 표시하지 않는다.

### 2.3 제품과 한도 선택

제품 선택지는 다음 세 가지다.

- Codex — 기본값
- Spark
- Codex와 Spark

자동 한도는 아래 순서로 하나를 선택한다.

1. 300분 한도
2. 10,080분 한도
3. 가장 짧은 양수 duration
4. duration이 모두 없으면 primary, 이후 secondary

사용자는 자동 선택을 끄고 제품·한도 조합을 직접 체크할 수 있다. 직접 선택한 항목이 응답에서 사라지면 선택을 삭제하거나 다른 항목으로 대체하지 않고 `현재 없음`으로 유지한다.

직접 선택 식별자는 제품과 서버의 raw duration으로만 구성한다. slot이나 reset 시각은 식별자에 넣지 않는다. 같은 제품·duration의 window가 둘 이상이면 남은 값이 적은 항목, reset이 더 늦은 항목, primary 순서로 하나를 고른다. 자동 선택이 기간 미상까지 내려간 경우에는 이 중복 규칙보다 primary, secondary slot 순서를 우선한다.

### 2.4 여러 frame 순환

- frame 하나이면 순환 timer를 만들지 않는다.
- frame이 여러 개이면 5초마다 다음 frame을 표시한다.
- 두 제품의 같은 기간은 하나의 비교 frame으로 묶는다.
- 자동 `Codex와 Spark` 모드는 선택 결과의 기간이 달라도 하나의 비교 frame으로 표시한다.
- 수동 모드는 같은 raw duration의 두 제품만 묶고 나머지는 단일 frame으로 유지한다.
- 기간이 짧은 순서로 정렬하고 기간 미상은 마지막에 둔다.
- 메뉴가 열렸거나 화면이 잠겼거나 Mac이 sleep 중이면 순환을 멈춘다.
- VoiceOver 또는 Reduce Motion이 활성화된 경우 순환하지 않는다.
- 순환 tick에서는 미리 만든 title 교체만 수행하며 프로세스·네트워크·디스크 I/O를 하지 않는다.
- 중단 사유가 모두 사라지면 첫 frame부터 다시 표시하고 5초 뒤 다음 frame으로 이동한다. 중단 중 놓친 tick은 따라잡지 않는다.

### 2.5 접근성

상태 항목의 접근성 label은 축약어를 풀어 쓴 완전한 문장이어야 한다. 기본 한국어에서는 예를 들어 `Codex 5시간 한도 남은 사용량 83퍼센트`로 읽고, 영어 locale에서는 같은 의미를 영어 resource로 구성한다. 두 제품, stale, 조회 중, 조회 불가 상태도 각 locale에서 의미가 완전히 전달되어야 한다.

- stale: `Codex 5시간 한도 남은 사용량 마지막 확인값 83퍼센트`
- 조회 중: `Codex 5시간 한도 사용량 확인 중`
- 조회 불가: `Codex 5시간 한도 사용량 확인 불가`
- 비교 frame: 제품별 문장을 Codex, Spark 순서로 쉼표와 함께 연결

## 3. 메뉴

메뉴는 조회 완료를 기다리지 않고 현재 메모리 snapshot으로 즉시 열린다.

- Codex와 Spark의 모든 quota window
- 제품별 별도 지출 한도 정보(서버가 해석 가능한 값을 제공한 경우)
- 각 window의 남은 퍼센트와 절대 reset 시각
- 마지막 성공 시각과 stale 또는 오류 이유
- `새로 고침`
- 상황에 맞는 `Codex 열기` 또는 `Codex 선택…`
- `설정…`
- `종료`

reset 상대 시간은 메뉴를 구성하는 시점에만 계산한다. 매초 countdown을 갱신하지 않는다. 조회 중 spinner나 상태바 애니메이션도 사용하지 않는다.

상세 메뉴의 quota 행도 상태바와 같은 유효성 정책을 사용한다. 현재 시각이 해당 window의 reset 시각과 같아졌거나 제품 값의 확인 시각으로부터 정확히 24시간이 되면 과거 퍼센트를 표시하지 않는다. 기간과 서버가 준 reset 절대 시각은 맥락으로 유지하되 값은 `—`와 `새로 고침 필요`로 표시한다. 한 제품의 window 일부만 만료되면 해당 행만 바꾸고 아직 유효한 sibling window는 정상 퍼센트를 유지한다. 이 전환은 지출 한도, 마지막 성공 시각, fresh·stale 오류 설명과 메뉴 action을 제거하지 않는다.

지출 한도는 quota window 행과 섞지 않고 해당 제품 section의 별도 정보 행으로 표시한다. 서버가 `도달`을 true로 제공하면 남은 비율이 함께 있어도 도달 상태를 우선한다. 도달 정보 없이 남은 비율만 있으면 `지출 한도 · 64% 남음`처럼 표시하고, 도달하지 않았다는 정보만 있고 비율을 해석할 수 없으면 `지출 한도 미도달 · 남은 비율 확인 불가`로 사실의 범위를 드러낸다. 값이 없거나 해석할 수 없는 제품에는 행을 만들지 않으며 다른 제품의 지출 한도나 quota 상태에 영향을 주지 않는다. 지출 한도는 상태바 frame, 순환과 고정 폭 계산에는 사용하지 않는다.

`Codex 열기`는 `NSWorkspace`가 열 수 있는 Codex application bundle이 실제로 있을 때만 제공한다. CLI-only 설치처럼 사용량은 조회할 수 있어도 열 application이 없으면 무동작 항목 대신 `Codex 선택…`을 제공한다.

## 4. 설정 창

설정은 popover가 아니라 약 440pt 폭의 일반적인 단일 macOS 창이다. Dock 아이콘이 없는 앱에서도 표준 창 동작, 키보드 이동과 VoiceOver 탐색을 제공한다.

설정 항목:

- 앱 언어 — `한국어`, `English`
- 표시 제품
- 자동 한도 또는 직접 한도 선택
- 갱신 프리셋
- 로그인 시 실행 — 기본 꺼짐
- Codex 실행 파일 경로, 버전과 연결 상태
- 자동 탐색 실패 시 `Codex 선택…`
- 민감정보를 제거한 `진단 정보 복사`
- OpenAI 비공식 커뮤니티 프로젝트이며 OpenAI와 제휴하거나 보증받지 않고 experimental Codex App Server에 의존한다는 안내

앱은 UI 언어, 표시 제품과 자동·직접 한도 선택, 갱신 프리셋, 로그인 시 실행 의도, 사용자가 선택한 실행 파일 URL과 최초 실행 완료 여부만 설정으로 저장한다. 저장값이 없는 첫 실행에서는 `Locale.preferredLanguages` 순서에서 한국어와 영어 중 먼저 발견한 언어를 선택하고, 둘 다 없으면 영어를 선택한다. 이 concrete `ko` 또는 `en` 값을 즉시 저장하므로 이후 시스템 언어 변경이 사용자 선택을 덮어쓰지 않는다. 기존 schema의 언어 없는 설정도 같은 규칙으로 한 번 이주한다. `hasCompletedFirstLaunch` 초기화는 저장 언어와 독립적이다.

기본값은 Codex 자동 한도, 균형 갱신, 로그인 시 실행 꺼짐, 선택 경로 없음과 최초 실행 미완료다. 직접 한도에는 현재 표시 제품과 일치하는 식별자만 저장하며, 필터링 뒤 선택이 비면 자동 선택으로 복구한다. 이 정규화는 앱에서 만든 값과 현재·이전 schema의 저장값에 똑같이 적용한다. 실행 파일 선택은 file URL만 허용한다. 손상되거나 미래 버전인 설정은 안전한 기본값으로 복구하며 quota snapshot, 퍼센트, 계정 상태, 오류와 원문 응답은 저장하지 않는다.

언어를 변경하면 같은 window와 view controller를 유지한 채 window title, section과 control title, quota 행, 연결·로그인 상태, 안내문과 접근성 label을 즉시 다시 현지화한다. 상태 항목의 compact title은 언어 중립 표기를 유지하지만 VoiceOver 문구와 이미 구성된 상세 메뉴는 선택 언어로 즉시 다시 만든다. 이 전환은 provider 조회, child 시작, polling 재예약이나 deadline 재등록을 만들지 않는다. 진단 복사 본문의 안정적인 machine-readable key는 번역하지 않는다.

로그인 시 실행은 macOS 13 이상의 `SMAppService.mainApp`으로 등록한다. 이미 원하는 상태이면 중복 등록·해제를 호출하지 않는다. 시스템에서 승인이 필요한 상태는 성공처럼 숨기거나 반복 등록하지 않고 혼합 상태의 checkbox, 설명 문구와 `시스템 설정 열기` 동작으로 구분한다. 사용할 수 없는 상태에서는 checkbox를 끈 상태로 비활성화한다. 저장된 의도보다 현재 시스템 상태를 실제 동작의 기준으로 표시하며, 창을 다시 표시할 때와 System Settings에서 앱으로 돌아올 때도 시스템 상태를 다시 읽는다.

등록과 해제 실패는 각각 정제된 사용자 문구만 표시하고 `NSError`의 domain, code와 description을 노출하지 않는다. 실패 뒤 실제 상태와 저장 의도가 어긋난 경우 사용자가 같은 checkbox 값을 다시 선택해도 이를 새 요청으로 전달해 등록·해제를 재시도할 수 있어야 한다. form 값 저장과 시스템 변경 요청은 별도 단방향 callback으로 전달하며, 열린 설정 창에는 시작 reconcile과 각 사용자 요청의 실제 상태·typed 실패 결과를 즉시 반영한다.

표시 제품은 Codex, Spark, 둘 다 중 하나를 고른다. 직접 선택에서는 현재 메모리 snapshot에서 발견한 제품·raw duration 식별자를 checkbox로 제공하며, 저장된 식별자가 새 응답에서 사라져도 행을 삭제하지 않고 `현재 없음`으로 남겨 사용자가 선택을 해제할 수 있게 한다. 제품을 바꾸면 직접 선택의 유효 범위를 새 표시 제품으로 제한하고 유효한 선택이 하나도 없으면 안전하게 자동 선택으로 저장한다. 자동 선택에서는 같은 행을 읽기 전용으로 보여준다. 로그인 시 실행 checkbox event는 설정 의도 저장과 별도의 runtime 요청으로 나뉘며 실제 `SMAppService` 등록은 로그인 실행 adapter만 담당한다.

창은 한 번에 하나만 연다. 닫으면 window controller, view controller와 관련 view의 강한 참조를 제거한다. 다음에 열 때 `UserDefaults`에서 설정을 읽어 화면을 다시 구성한다. allocator 특성상 프로세스 RSS가 즉시 줄지 않을 수 있지만 객체 graph는 해제되어야 한다. 실행 파일 선택 panel이 열린 상태에서 창을 닫거나 앱 종료를 시작하면 panel을 취소하고 continuation을 정확히 한 번 완료한다. 늦게 도착한 panel 응답은 무시하며 다시 연 창의 새 선택 작업과 섞지 않는다.

Dock 아이콘이 없는 `LSUIElement`·accessory 앱에서도 설정이 다른 앱 뒤에 비활성 상태로 남지 않게 한다. 최초 실행과 메뉴의 `설정…`은 같은 표시 경계를 사용하며, 표시 가능한 window가 있고 종료가 시작되지 않았음을 먼저 확인한 뒤 앱을 foreground로 활성화하고 window를 key/front로 올린다. 이미 열린 창을 다시 요청할 때도 같은 순서를 한 번 수행한다. window 생성이 완료되지 않았거나 취소·종료로 표시가 거부된 요청은 앱을 불필요하게 활성화하지 않는다.

연결 영역의 경로는 절대 경로 대신 `자동 감지` 또는 `사용자 선택` 출처와 안전한 executable basename을 표시한다. basename을 안전하게 표현할 수 없으면 애플리케이션 내부, Homebrew, 사용자 로컬 CLI 또는 기타 위치처럼 일반화한다. 연결 상태는 연결됨, 확인 중, 찾을 수 없음, 잘못된 선택, 로그아웃, 지원하지 않는 인증, 비호환 버전, timeout과 process 실패를 구분한다. 메모리의 연결 상태 변경은 별도 I/O 없이 열린 화면과 진단 복사 snapshot에 즉시 반영한다. 동시에 진행 중인 CLI version probe가 끝나도 시작 시점의 오래된 연결 상태로 이를 덮어쓰지 않는다.

진단 복사에는 앱 버전, macOS 버전, architecture, CLI 버전, typed 연결·version 오류 code와 경로 출처·일반화 category만 포함한다. 절대 경로, 이메일, token, raw JSON과 원문 process 출력은 포함하지 않는다.

앱 종료용 설정 coordinator shutdown은 terminal drain이다. 이미 queue에 들어간 form 저장을 마치고, diagnostics probe를 취소한 뒤 process cleanup을 기다리며, 미확정 선택 panel은 취소한다. URL 저장을 시작한 선택은 저장과 runtime callback까지 마친 뒤 종료한다. 저장 대기 중이던 창 표시 요청과 shutdown 이후 새 요청에는 창을 반환하지 않으며, 경쟁으로 이미 생성한 창도 즉시 닫고 해제한다.

실행 파일 선택 저장 중 원래 설정 창을 닫고 다시 열어도 commit 결과는 현재 열린 창을 기준으로 적용한다. 새 창의 이전 경로·상태를 먼저 `확인 중`으로 지우고 선택된 URL로 diagnostics를 다시 시작해, 닫힌 창을 대상으로 한 결과가 화면을 stale 상태에 남기지 않게 한다.

## 5. 최초 실행

1. 시스템 선호 언어에서 한국어·영어 bootstrap 언어를 결정하고 상태 항목을 가장 먼저 만든다.
2. 설정을 읽어 저장 언어가 있으면 그 값을 적용하고, 저장값이 없으면 bootstrap 언어를 concrete 값으로 저장한다.
3. 초기 사용량 조회를 비동기로 시작한다.
4. 상태 항목이 표시되고 refresh coordinator에 초기 시작 명령을 전달한 뒤 최초 실행 여부를 한 번 판단한다. 사용량 응답 완료를 기다리지는 않는다.
5. 최초 실행에만 설정 창을 열어 연결 영역을 보여준다.
6. 설정 창이 실제 visible 상태로 표시된 경우에만 `hasCompletedFirstLaunch`를 기록한다. visible 결과를 얻은 뒤에는 shutdown cancellation과 경쟁하더라도 완료 기록을 끝까지 기다린다.
7. 창 표시를 시작하기 전에 취소되었거나 shutdown과 경쟁해 visible 결과를 얻지 못하면 기록하지 않으며, 같은 process에서는 자동 표시를 다시 시도하지 않고 다음 앱 실행에서 재시도한다.
8. 이후 실행에서는 사용자가 메뉴의 `설정…`을 선택할 때만 창을 연다.

별도 튜토리얼이나 온보딩 창은 만들지 않는다. UI 테스트는 명시적인 `--codex-gauge-ui-test-reset-first-launch` launch argument로 최초 실행 완료 여부만 false로 되돌릴 수 있다. 이 seam은 표시·갱신·로그인·선택 executable 설정을 보존하고 defaults domain이나 다른 사용자 데이터를 삭제하지 않는다. 같은 실행에서 설정 창이 실제로 표시되면 완료 여부는 다시 true가 된다.

Debug 구성의 통합 XCUITest는 정확한 `--codex-gauge-ui-test-fixture-83` launch argument를 사용한다. 이 인자는 런타임 표시 설정만 Codex 자동 선택으로 덮어써 상태 항목에 합성 `[5h] 83%`를 게시하며, 최초 실행 완료 여부는 바꾸지 않는다. 최초 실행을 재현할 때만 별도의 `--codex-gauge-ui-test-reset-first-launch`를 함께 전달한다. 따라서 후속 실행은 fixture를 유지하면서 reset 인자를 빼면 동일한 격리 환경에서 설정 창의 한 번만 자동 표시되는 계약을 검증할 수 있다. 저장된 표시·갱신·로그인·선택 executable 값은 변경하지 않는다. fixture에서도 실제 상태 항목, 상세 메뉴와 설정 창을 사용하지만 Codex를 탐색하거나 실행하지 않고, App Server·인증·네트워크와 `SMAppService`에 접근하지 않는다. 비슷한 이름의 인자와 일반 실행에서는 이 모드를 활성화하지 않으며 Release 빌드는 정확한 인자도 무시하고 production 모드로 실행한다.

## 6. 갱신 프리셋

| 프리셋 | 평상시 간격 | quota 정수 퍼센트 증가 후 | 용도 |
| --- | ---: | ---: | --- |
| 수동 | 없음 | 없음 | 시작 시 1회 및 수동 갱신 |
| 절전 | 10분 | 60초 | 배터리 우선 |
| 균형 | 3분 | 20초 | 기본값 |
| 빠름 | 1분 | 10초 | 최신성 우선 |

증가 감지는 프로세스 실행 여부가 아니라 같은 reset cycle에서 선택된 quota의 정수 `usedPercent`가 증가했는지를 뜻한다. 비교 표본은 제품, 서버의 raw duration과 reset 시각을 하나의 identity로 사용하며 `usedPercent`는 내림한 정수로 비교한다. 실제 사용 중에도 정수 값이 그대로이면 burst가 늦게 시작될 수 있다.

- 시작 후 첫 성공과 wake 또는 unlock 후 성공은 새 baseline만 만들며 burst를 시작하지 않는다.
- 같은 identity의 값이 하나라도 증가하면 burst를 시작하거나 종료 시점을 연장한다. 값이 같으면 연장하지 않는다.
- 다른 identity의 증가가 함께 있지 않은 상태에서 값이 감소하거나 선택된 identity 또는 reset cycle이 바뀌면 새 baseline으로 교체하고 기존 burst를 끝낸다.
- 증가가 감지되면 5분 동안 burst 간격을 사용한다.
- 추가 증가가 있으면 burst 종료 시점을 다시 5분 뒤로 옮긴다.
- 5분간 증가가 없거나 연속 3회 실패하면 평상시 상태로 돌아간다.
- Low Power Mode에서는 설정값이 빠르더라도 최소 절전 프리셋의 간격을 적용한다.
- sleep과 화면 잠금 중에는 조회와 순환을 중단한다.
- sleep과 화면 잠금이 겹치면 두 중단 사유가 모두 해제된 뒤에만 갱신을 재개한다.
- 자동 프리셋은 wake 또는 unlock 5초 뒤 한 번 조회하며 sleep 전 값과 비교해 burst를 시작하지 않는다. 수동 프리셋은 시작 시 1회와 사용자가 요청한 갱신만 실행하며 wake 조회와 자동 재시도를 예약하지 않는다.
- reset 시각에는 단발 조회하되 실패했다고 100%로 추측하지 않는다.
- 중단 중 또는 wake 5초 대기 중 reset이 도래하면 별도 조회를 만들거나 신호를 버리지 않는다. reset을 wake 조회에 합쳐 원래 5초 시점에 reset baseline 한 번만 조회한다.

메모리에 게시된 제품별 상태에는 polling timer와 별도로 wall-clock one-shot deadline 하나만 둔다. Codex와 Spark에서 quota window가 있는 fresh 또는 stale value마다 quota reset과 해당 value의 `capturedAt + 24시간`을 독립적으로 보존하고, 아직 처리하지 않은 가장 이른 시각을 예약한다. loading, unavailable과 quota가 없는 value는 deadline을 만들지 않는다. quota reset 도래는 기존 표시를 즉시 재평가하면서 reset 조회 신호를 보내고, 24시간 유효기간 도래는 provider 조회 없이 표시만 다시 계산해 `—`로 바꾼다. terminal 오류로 자동 polling이 멈춘 상태에서도 유효기간 전환은 동작해야 한다. 새 제품 상태 publication, wake와 시스템 시계 변경에서 deadline을 다시 계산하고 sleep과 stop에서는 취소한다. 이미 지난 deadline은 종류별로 즉시 한 번만 처리하며 reset 도래를 `100%` 사용으로 추측하지 않는다.

설정에서 프리셋을 바꾸면 실행 중인 앱에 즉시 적용한다. 자동 프리셋끼리 바꿀 때 진행 중인 조회는 중단하지 않고 그 결과 이후부터 새 간격을 적용하며, 진행 중인 조회가 없으면 현재 시각부터 새 간격으로 다시 예약한다. 이미 예약된 일시 실패 재시도는 간격을 바꾸지 않는다. 수동으로 바꾸면 진행 중인 자동 조회와 예약을 취소하고 burst와 실패 횟수를 지우되 마지막 비교 baseline은 유지한다. 수동에서 자동으로 바꿀 때 즉시 조회하지 않고 현재 시각부터 새 평상시 간격을 예약한다.

## 7. 상태와 오류

| 상태 | 상태바 | 메뉴 동작 |
| --- | --- | --- |
| 첫 조회 중 | `…` | 연결 확인 중 표시 |
| 정상 | 남은 `%` | 마지막 성공·reset 정보 표시 |
| 정상 응답, quota 없음 | `—` | 연결됨과 현재 사용 가능한 quota 없음 표시 |
| 일시 실패, 기존 값 유효 | `~%` | 기존 값과 오류 원인 표시 |
| 24시간 초과 또는 reset 경과 | `—` | 값 대신 재시도 안내 |
| 로그아웃 | `—` | Codex에서 로그인하도록 안내 |
| Codex 미발견 | `—` | 열기 또는 실행 파일 선택 제공 |
| timeout | 기존 값에 `~` 또는 `—` | 재시도 상태 표시 |
| 프로토콜 비호환 | 기존 값에 `~` 또는 `—` | 지원되지 않는 버전 표시 |

제품별 상태를 독립적으로 유지한다. 한 제품만 성공한 경우 성공한 제품은 새 값으로 바꾸고 나머지만 stale 처리한다. 오류 메시지에는 token, 이메일, 원문 JSON이나 사용자 경로를 노출하지 않는다.

정상적으로 해석된 제품 상태가 `unavailable`이고 window가 비어 있으면 이전 성공값이 있더라도 상태바 값을 즉시 `—`로 바꾼다. 이는 실패가 아니라 현재 제공되는 quota가 없다는 새 사실이므로 `~`로 보존하지 않는다. 반대로 제품 payload가 malformed이고 window가 비어 있으면 유효기간 안의 이전 성공값만 stale로 보존하며, 이전 값이 없으면 `—`로 표시한다. 정상 window가 하나라도 있는 partial 결과는 해당 window를 fresh로 갱신하고 partial 사유를 별도로 보여준다.

마지막 성공 시각으로부터 정확히 24시간이 되었거나 현재 시각이 해당 window의 reset 시각에 도달하면 그 값은 stale이 아니라 조회 불가로 처리한다. 두 조건 중 먼저 도달하는 시점이 유효기간의 끝이다.

이 경계 전환은 다음 polling 성공을 기다리지 않는다. wall-clock one-shot이 presentation invalidation을 요청해 cached frame을 현재 시각으로 다시 만들며, reset과 제품별 24시간 경계가 같으면 timer 하나에서 두 typed reason을 중복 없이 처리한다.

## 8. 배포와 업데이트

### 8.1 설치

- macOS 13 이상에서 동작하는 Apple Silicon·Intel universal application을 제공한다.
- 기본 채널은 GitHub Releases의 `CodexGauge.dmg`다.
- DMG의 사용자 표시 root에는 application bundle, `/Applications` symbolic link와 비실행 `설치 안내 - Installation.txt`를 둔다.
- 숨김 root에는 640×420 Finder 배경용 `.background`와 layout metadata `.DS_Store`만 둔다.
- 사용자는 DMG에서 Codex Gauge를 Applications로 드래그한다.
- Apple Developer Program, Developer ID 배포 서명과 Apple notarization을 사용하지 않는다.
- application은 Apple 인증서 없이 ad-hoc code signing하지만 이를 개발자 신원이나 Gatekeeper 승인으로 표현하지 않는다.
- macOS가 최초 실행을 차단하면 사용자가 System Settings의 공식 `그래도 열기` 절차로 직접 승인한다.
- 앱, DMG, packaging automation과 Cask는 quarantine 제거, Gatekeeper 설정 변경 또는 최초 실행 승인을 자동화하지 않는다.
- 설치 안내는 공식 `그래도 열기` 절차를 우선하고, 공식 Release와 정확한 `/Applications/Codex Gauge.app` 경로를 확인한 사용자가 선택할 수 있도록 해당 앱 하나의 quarantine marker를 제거하는 정확한 수동 대안을 제공한다.
- 수동 대안은 설치·권한 부여·Apple 검증이 아니라 해당 앱의 quarantine 기반 Gatekeeper 최초 평가를 우회하는 동작임을 밝힌다. `sudo`, 넓은 경로, 전역 Gatekeeper 변경과 executable helper는 제공하지 않는다.
- SHA-256은 artifact 일치와 전송 손상을 확인하지만 개발자 신원이나 Apple 검증을 의미하지 않는다.
- PKG, privileged helper와 installer script를 만들지 않는다.

자체 Homebrew Cask는 같은 versioned GitHub Release DMG와 정확한 SHA-256을 사용한다. `app` artifact만 사용하며 postflight script나 macOS 보안 설정 변경을 추가하지 않는다. Homebrew 설치에서도 최초 실행 승인이 필요할 수 있다.

### 8.2 자동 업데이트

Sparkle 2 기반 자동 업데이트는 DMG와 GitHub Release 기반을 검증한 뒤 별도 task로 도입한다. HTTPS appcast와 EdDSA 서명을 사용하며 Developer ID가 없는 환경의 구버전→신버전 교체와 Gatekeeper 동작을 실제 설치본에서 검증한다.

- 메뉴에 `업데이트 확인…`을 제공한다.
- 자동 확인은 기본 켜짐이고 하루 한 번 실행한다.
- 자동 다운로드와 설치는 기본 꺼짐이다.
- quota polling과 update schedule을 결합하지 않는다.
- 익명 system profiling과 telemetry를 사용하지 않는다.
- 첫 안정 공개 버전 전에 updater를 포함해 기존 사용자가 한 번 수동 설치해야 하는 전환을 피하는 것을 목표로 한다.

구체적인 artifact와 신뢰 경계는 [배포 문서](distribution.md)를 따른다.

## 9. v0.1 제외 범위

- token 통계, 히스토리와 그래프
- 낮은 사용량 알림
- 다중 계정 동시 표시
- App Store 배포
- private Codex IPC 재사용
- 서버가 주지 않은 월간 의미 추론
- SwiftUI, Electron, Tauri와 WebView
- telemetry와 외부 crash SDK
