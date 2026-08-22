# Codex Gauge 설치 / Installation

> 설치하려면 `CodexGauge.dmg`를 다운로드하세요. GitHub가 자동으로 제공하는 Source code 링크는 애플리케이션 설치 파일이 아닙니다.
>
> Download `CodexGauge.dmg` to install the app. GitHub's automatically generated Source code links are not application installers.

1. DMG를 열고 `Codex Gauge.app`을 `Applications`로 드래그합니다.
2. Applications 또는 Spotlight에서 Codex Gauge를 실행합니다.
3. macOS가 실행을 차단하면 `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`에서 직접 승인합니다.

1. Open the DMG and drag `Codex Gauge.app` to `Applications`.
2. Launch Codex Gauge from Applications or Spotlight.
3. If macOS blocks the first launch, approve it in `System Settings → Privacy & Security → Open Anyway`.

Codex Gauge는 Apple Developer Program을 사용하지 않으며 Developer ID 서명과 Apple 공증 없이 배포됩니다. 앱과 설치 과정은 Gatekeeper 또는 quarantine을 우회하지 않습니다.

Codex Gauge is distributed without Developer ID signing or Apple notarization. Neither the app nor its installer bypasses Gatekeeper or quarantine.

## 무결성 확인 / Integrity check

같이 제공되는 `CodexGauge.dmg.sha256`으로 다운로드 손상 여부를 확인할 수 있습니다. SHA-256은 Apple의 개발자 신원 확인이나 공증을 대신하지 않습니다.

The accompanying `CodexGauge.dmg.sha256` can detect download corruption. SHA-256 does not replace Apple developer identity verification or notarization.

```sh
shasum -a 256 -c CodexGauge.dmg.sha256
```

## 변경 사항 / Changes

이 초안은 공개 전에 실제 변경 사항과 설치 검증 결과를 추가해야 합니다.

Add the actual changes and installation verification results before publishing this draft.
