# Codex Gauge

Codex Gauge는 macOS 메뉴 막대에서 Codex와 Spark의 남은 사용 한도를 빠르게 확인하는 가벼운 네이티브 앱입니다. 평상시에는 짧은 상태 문자열만 유지하고, 설정 창과 Codex App Server 프로세스는 필요할 때만 사용해 CPU·메모리·wake-up을 줄이는 것을 우선합니다.

> Codex Gauge는 OpenAI의 공식 제품이 아닌 커뮤니티 프로젝트이며 OpenAI의 보증이나 제휴를 받지 않습니다. 실험적 Codex App Server 인터페이스에 의존하므로 Codex 버전에 따라 조회 기능이 일시적으로 동작하지 않을 수 있습니다.

## 목표

- 메뉴 막대에 `[5h] 83%`, `[w] C75% · S82%`처럼 짧게 표시
- Codex, Spark 또는 두 제품을 함께 선택
- 5시간·일간·주간 등 서버가 제공한 기간을 추측 없이 표현
- 3분 평상시 조회와 변화 감지 후 20초 burst를 사용하는 균형 프리셋
- sleep, 화면 잠금, Low Power Mode에서 불필요한 작업 중단
- 설정 창을 닫으면 관련 AppKit 객체를 해제
- 인증 정보, 계정 이메일, 원문 응답 및 사용량 기록을 저장하지 않음

## 상태 표시

| 예 | 의미 |
| --- | --- |
| `[5h] 83%` | Codex 5시간 한도가 83% 남음 |
| `S[w] 91%` | Spark 주간 한도가 91% 남음 |
| `[w] C75% · S82%` | 같은 기간의 Codex·Spark 한도를 함께 표시 |
| `[5h] ~83%` | 최근 조회에 실패해 마지막 성공값을 표시 |
| `[5h] …` | 첫 조회 진행 중 |
| `[5h] —` | 신뢰할 수 있는 값이 없음 |

상태 항목을 누르면 모든 한도, reset 시각, 마지막 갱신 시각, 연결 상태와 설정 메뉴를 확인할 수 있습니다. 상세 UX는 [제품 사양](docs/product-spec.md)을 참고하세요.

## 요구 환경

- macOS 13 이상
- Codex가 포함된 OpenAI 데스크톱 앱 또는 호환 Codex CLI
- 개발: Xcode 26.6, Swift 6 language mode
- 실행 대상: Apple Silicon 및 Intel Mac

Codex Gauge는 별도의 OpenAI API key를 요구하지 않습니다. 설치된 Codex가 소유한 인증 경계를 그대로 사용합니다.

## 개발 상태와 빌드

v0.1을 개발 중입니다. 핵심 모듈과 AppKit 개발 호스트는 Swift Package Manager로 빌드하고 테스트할 수 있습니다.

```sh
swift build
swift run codex-gauge-tests
swift build -c release
```

실제 `.app`은 root package의 `CodexGaugeAppKit` product를 연결한 얇은 Xcode application target으로 빌드합니다. shared `CodexGauge` scheme에는 application, unit test와 UI test target이 포함됩니다.

```sh
xcodebuild -project CodexGauge.xcodeproj \
  -scheme CodexGauge \
  -destination 'platform=macOS' \
  -only-testing:CodexGaugeUnitTests \
  test

xcodebuild -project CodexGauge.xcodeproj \
  -scheme CodexGauge \
  -destination 'platform=macOS' \
  -only-testing:CodexGaugeUITests \
  test
```

공개 CI는 SwiftPM 전체 테스트와 Xcode unit smoke, main·수동 실행의 UI smoke 및 signing-disabled universal Release 빌드를 검증합니다. 사용자 인증이나 실제 Codex 설치에 의존하지 않으며 protocol 테스트는 합성 fixture만 사용합니다. 실제 App Server smoke test는 개발자가 명시적으로 실행하는 로컬 테스트로만 제공합니다.

Debug 구성의 XCUITest에서 실제 메뉴 막대·메뉴·설정 창 composition을 검증할 때는 정확한 `--codex-gauge-ui-test-fixture-83` 실행 인자를 사용합니다. 이 opt-in 모드는 메모리에 합성 Codex 5시간 한도 `83%`를 게시하며 Codex 탐색·프로세스·인증·네트워크와 로그인 항목 변경을 수행하지 않습니다. Release 빌드는 같은 인자를 무시하고 항상 production 경계를 사용하며, 일반 실행에도 이 인자를 전달하지 않습니다.

## 개인정보와 보안

- `~/.codex/auth.json` 같은 인증 파일을 직접 읽지 않습니다.
- 원문 JSON, access token, 이메일, 로컬 세션 로그를 저장하거나 출력하지 않습니다.
- quota snapshot은 메모리에만 유지하고 앱을 다시 실행하면 새로 조회합니다.
- 설정에는 표시 방식, 갱신 프리셋, 선택한 실행 파일 경로 같은 비밀이 아닌 값만 저장합니다.
- shell이나 비공개 IPC 대신 공식 App Server JSONL 인터페이스를 사용합니다.

자세한 경계는 [프로토콜 문서](docs/codex-protocol.md)와 [보안 정책](SECURITY.md)을 참고하세요.

## 문서

- [제품 사양](docs/product-spec.md)
- [아키텍처](docs/architecture.md)
- [Codex 프로토콜](docs/codex-protocol.md)
- [개발 및 테스트](docs/development.md)
- [기여 안내](CONTRIBUTING.md)

## 라이선스

[MIT License](LICENSE)
