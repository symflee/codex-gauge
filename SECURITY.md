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
- App Server child에는 인증에 필요한 부모 환경을 그대로 상속하되 `PATH`만 고정된 system·Homebrew 목록으로 교체하고, 환경값을 영속 저장·로그하지 않음
- 공식 App Server JSONL method만 사용
- token, 이메일, raw JSONL, stderr와 quota history를 저장하지 않음
- telemetry와 외부 analytics·crash SDK를 사용하지 않음
- 설정에는 비밀이 아닌 preference만 저장
- 진단 정보에서 사용자 경로와 계정 정보를 제거

## 배포 신뢰 경계

Codex Gauge의 공개 앱은 Apple 인증서와 공증 없이 GitHub Release DMG와 자체 Homebrew Cask로 배포하며 다음 경계를 지킨다.

- application은 Apple 인증서 없는 ad-hoc signing을 사용하며 이를 개발자 신원이나 Gatekeeper 승인으로 표현하지 않음
- DMG의 사용자 표시 항목은 application bundle, `/Applications` symbolic link와 비실행 한·영 설치 안내 파일로 제한하고, 숨김 지원 항목은 640×420 배경의 `.background`와 Finder layout `.DS_Store`로 제한
- installer script, privileged helper와 PKG를 사용하지 않음
- 프로젝트 소유 앱 코드, DMG, packaging script, workflow와 Cask는 `xattr`, `spctl`, Gatekeeper 전역 설정 변경 또는 최초 실행 승인 자동화를 수행하지 않음
- macOS가 차단하면 사용자가 System Settings의 공식 `그래도 열기` 절차로 직접 승인
- 공식 Release와 정확한 설치 경로를 확인한 사용자가 공식 절차 이후 선택할 수 있도록 `/Applications/Codex Gauge.app` 하나의 quarantine marker를 제거하는 정확한 수동 명령만 문서화함
- 수동 대안은 설치·권한 부여·Apple 검증이 아니며 해당 앱의 quarantine 기반 Gatekeeper 최초 평가를 우회한다는 사실을 숨기지 않음
- `sudo`, 다른 앱이나 넓은 경로의 quarantine 제거, Gatekeeper 전역 비활성화, executable helper와 postflight script를 안내하거나 제공하지 않음
- SHA-256을 artifact 일치 확인에만 사용하고 개발자 신원이나 Apple 검증으로 표현하지 않음
- release artifact와 CI log에 credential, 실제 quota와 사용자 경로를 포함하지 않음

Sparkle 2.9.6 updater는 quota polling·인증 경계와 분리하고 다음 신뢰 경계를 지킨다.

- feed는 `https://github.com/symflee/codex-gauge/releases/latest/download/appcast.xml`, update enclosure는 version이 드러나는 exact-tag 경로 `https://github.com/symflee/codex-gauge/releases/download/vX.Y.Z/CodexGauge.dmg`만 사용하며 경로 자체가 asset 불변성을 보장한다고 가정하지 않음
- HTTPS transport에 더해 appcast와 full DMG의 Sparkle EdDSA signature를 모두 확인하고, `SUVerifyUpdateBeforeExtraction=YES`, `SURequireSignedFeed=YES`, `SUSignedFeedFailureExpirationInterval=0`으로 signature 누락·실패·만료·wrong key와 archive 변조를 설치 없이 거부
- EdDSA 공개키와 제3자 license 고지만 application bundle에 포함하고 개인키, recovery material과 서명 전후 임시 파일은 포함하지 않음
- 앱 실행 시 정보 조회를 한 번만 수행하고 Sparkle scheduler는 끈다. 새 버전을 발견해도 자동 download와 install을 모두 금지하며 사용자가 표준 update 창의 `업데이트`를 누른 경우에만 application replacement를 시작
- stable full DMG만 허용하며 beta, delta, phased rollout, critical·forced update와 downgrade를 사용하지 않음
- release notes rendering과 system profiling을 끄고 telemetry, account·quota 값, Codex 인증 또는 사용자 설치 경로를 appcast request에 추가하지 않음
- 마지막 확인 시각, skipped version과 temporary download cache는 Sparkle의 local metadata로만 유지하고 quota snapshot이나 raw App Server 응답과 결합하지 않음

EdDSA 공개키는 `Distribution/SparklePublicEdKey.txt`에 저장한다. 개인키는 GitHub repository Actions secret에서 release signing step에만 전달하고 repository, command argument, log, workflow artifact 또는 GitHub Release asset에 기록하지 않는다.

공개 main application은 ad-hoc signed Sparkle framework를 process 안에 load하기 위해 entitlement dictionary에 `com.apple.security.cs.disable-library-validation=true` 항목 하나만 둔다. Sparkle framework, `Autoupdate`, `Updater`와 그 밖의 nested executable에는 entitlement를 적용하지 않는다. Hardened Runtime은 모든 실행 코드에서 유지하며 `allow-dyld-environment-variables`, `allow-unsigned-executable-memory`, `disable-executable-page-protection`, `get-task-allow` 같은 다른 runtime 예외는 추가하지 않는다.

이 선택은 main process가 load하는 framework의 서명 주체 제한을 완화한다. Release 검증은 main entitlement의 정확한 값, 다른 runtime 예외의 부재, bundle 내부 Sparkle 구조·nested signature와 Hardened Runtime을 확인한다. 내려받은 update의 출처와 무결성은 별도의 HTTPS와 Sparkle EdDSA feed·archive 검증으로 확인한다.

update 뒤 macOS가 승인을 다시 요구하면 공식 `그래도 열기` 절차만 우선 안내한다. 프로젝트 소유 코드와 배포 자동화는 `xattr`, `spctl`, Gatekeeper 전역 변경 또는 quarantine 제거 fallback을 실행하지 않는다. 다만 수정하지 않은 Sparkle updater는 사용자가 update를 승인한 뒤 표준 replacement 과정에서 staged application의 quarantine metadata를 정리하고 macOS system scan을 실행할 수 있다. 이 upstream 동작은 프로젝트가 최초 실행 승인이나 전역 보안 설정 변경을 자동화하는 경로가 아니다.

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
