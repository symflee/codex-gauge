# Codex Gauge에 기여하기

macOS 13 이상과 Swift 6 개발 환경을 사용합니다. 애플리케이션 빌드에는 전체 Xcode가 필요합니다. Swift package는 `Package.swift`, 앱 프로젝트는 `CodexGauge.xcodeproj`를 기준으로 합니다.

## 변경과 검증

한 pull request는 하나의 명확한 변경을 다룹니다. 비-UI 동작 변경은 실패를 재현하는 테스트부터 작성하고, 합성 데이터로 결과를 확인합니다. 실제 계정이나 Codex 로그인을 자동 테스트의 전제로 삼지 않습니다.

검증 명령은 checkout한 버전에 포함된 스크립트를 사용합니다.

- `Scripts/test-fast.sh`가 있으면 `--suite` 또는 `--filter`로 변경 영역을 지정합니다. 전체 기능 확인은 `--suite full`로 명시합니다.
- 이전 버전에서는 `Scripts/run-exhaustive-tests.sh`를 사용합니다.
- `Scripts/test-pr.sh`가 있는 버전은 PR 직전에 해당 검증을 한 번 수행합니다.
- 문서만 바뀌면 diff와 링크를 확인합니다. 앱 실행, UI와 배포 산출물 검증은 별도로 수행합니다.

같은 소스, 의존성, 옵션과 환경에서 통과한 검사는 관련 변경이나 미해결 위험이 없다면 반복하지 않습니다.

## 제출 기준

- 변경한 동작과 검증 결과를 설명합니다.
- 사용자 문자열은 localization resource로 관리합니다.
- 인증과 개인정보 처리, 외부 의존성 변경은 영향과 이유를 설명합니다.
- 실제 token, 이메일, 사용량, 원문 응답과 개인 경로를 코드, 테스트, issue와 PR에 포함하지 않습니다.
- 커밋 제목은 `<type>(<scope>): <한글 제목>`을 사용하고 관련 없는 변경을 섞지 않습니다.

보안 취약점은 공개 issue 대신 [보안 정책](SECURITY.md)의 신고 절차를 따릅니다.
