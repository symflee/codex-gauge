# Codex Gauge

macOS 메뉴 막대에서 Codex 사용 한도를 확인하는 가벼운 네이티브 앱입니다. OpenAI의 공식 제품이 아닌 커뮤니티 프로젝트이며, 설치된 Codex의 App Server 인터페이스를 사용합니다.

## 요구 환경

- macOS 13 이상
- 호환되는 Codex 앱 또는 CLI와 로그인된 계정

별도의 OpenAI API key를 입력할 필요가 없습니다. 지원 기능과 변경 사항은 설치한 버전의 Release 안내를 확인하세요.

## 설치와 업데이트

[GitHub Releases](https://github.com/symflee/codex-gauge/releases/latest)에서 `CodexGauge.dmg`를 내려받아 앱을 Applications로 드래그합니다. `Source code` 압축 파일은 설치 파일이 아닙니다.

Apple 배포 인증서와 공증을 사용하지 않으므로 macOS가 최초 실행을 차단할 수 있습니다. 이 경우 `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`에서 직접 승인합니다. 자세한 절차는 [설치 안내](https://github.com/symflee/codex-gauge/blob/main/docs/installation.md)를 참고하세요.

새 버전 설치 방법과 인앱 업데이트 지원 여부는 해당 Release 안내를 따릅니다.

## 사용

메뉴 막대에서 남은 한도를 확인하고 상태 항목을 눌러 상세 정보를 볼 수 있습니다. 값을 알 수 없는 상태를 남은 한도 `0%`로 표시하지 않습니다. Codex 버전이나 연결 상태에 따라 조회가 일시적으로 실패할 수 있습니다.

## 개인정보와 보안

인증 파일을 직접 읽거나 사용량 기록을 저장하지 않습니다. 원문 응답, token, 이메일을 로그에 남기지 않으며 telemetry를 사용하지 않습니다. 보안 문제 신고와 상세 정책은 [SECURITY.md](SECURITY.md)를 참고하세요.

## 소스와 기여

[기여 안내](CONTRIBUTING.md)에서 개발과 검증 방법을 확인할 수 있습니다. 라이선스는 [LICENSE](LICENSE)를 참고하세요.
