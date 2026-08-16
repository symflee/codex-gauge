# Security Policy

## 지원 범위

Codex Gauge는 첫 안정 릴리스 전까지 `main`의 최신 revision만 보안 수정을 받습니다. 릴리스가 시작되면 현재 지원 버전을 이 문서에 명시합니다.

Codex Gauge는 실험적 Codex App Server에 의존합니다. 정상적인 upstream schema 변경이나 일시적 조회 실패는 보안 취약점이 아닐 수 있지만, 인증 정보 노출·임의 코드 실행·권한 상승·원치 않는 데이터 전송 가능성이 있으면 보안 문제로 취급합니다.

## 비공개 신고

GitHub 저장소의 **Security → Report a vulnerability**를 사용해 private vulnerability report를 제출해 주세요. 보안 내용을 공개 issue, discussion 또는 pull request에 먼저 게시하지 마세요.

신고에 포함하면 좋은 내용:

- 영향을 받는 revision 또는 버전
- 재현 조건과 예상 영향
- 민감정보를 제거한 최소 재현 단계
- 가능하다면 완화 또는 수정 아이디어

실제 access token, 인증 파일, 이메일, raw App Server 응답, 앱 로그 전체 또는 개인 절대 경로를 첨부하지 마세요. 재현에 꼭 필요한 값은 가상의 placeholder로 바꾸세요.

유지관리자는 신고를 확인하고 영향과 수정 계획을 private report에서 공유합니다. 수정과 공개 시점은 위험도와 upstream 의존성을 고려해 조율합니다.

## 보안 경계

Codex Gauge는 다음 원칙을 지킵니다.

- 설치된 Codex 실행 파일이 소유한 인증을 재사용하며 인증 파일을 직접 읽지 않음
- shell을 거치지 않고 검증한 executable을 직접 실행
- 공식 App Server JSONL method만 사용
- token, 이메일, raw JSONL, stderr와 quota history를 저장하지 않음
- telemetry와 외부 analytics·crash SDK를 사용하지 않음
- 설정에는 비밀이 아닌 preference만 저장
- 진단 정보에서 사용자 경로와 계정 정보를 제거

명시적 `swift run codex-gauge-smoke` 검증도 같은 실행 파일 검증과 App Server session 경계를 사용합니다. no-argument CLI는 앱 설정의 선택 경로나 `NSWorkspace` 결과를 읽지 않고 알려진 자동 후보만 검사합니다. handshake와 한도 조회를 한 번 수행하고 bounded cleanup 뒤 종료하며, 제품 availability와 typed 실패 범주만 출력합니다. 실제 퍼센트, reset 시각, 이메일, token, account identifier, raw JSONL, stderr, 절대 경로와 하위 오류 설명은 출력하지 않습니다. 이 명령은 앱 시작, test suite 또는 CI에서 자동으로 실행하지 않습니다.

다음은 명시적으로 지원하지 않습니다.

- private IPC 또는 내부 database 접근
- 웹 dashboard scraping
- CLI의 사람이 읽는 출력 parsing
- access token 추출·복제·갱신
- 비공개 endpoint 호출

이 경계를 변경하는 제안은 구현 전에 security와 architecture 검토가 필요합니다.

## 민감정보를 발견한 경우

저장소, release artifact 또는 CI log에서 실제 credential이나 개인 데이터를 발견했다면 복사하거나 추가로 사용하지 말고 즉시 private vulnerability report로 위치만 알려주세요. Credential 소유자가 폐기·교체할 수 있도록 공개 노출을 최소화합니다.
