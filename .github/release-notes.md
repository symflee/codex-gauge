# Codex Gauge 설치 / Installation

> 설치하려면 `CodexGauge.dmg`를 다운로드하세요. GitHub가 자동으로 제공하는 Source code 링크는 애플리케이션 설치 파일이 아닙니다.
>
> Download `CodexGauge.dmg` to install the app. GitHub's automatically generated Source code links are not application installers.

1. DMG를 열고 `Codex Gauge.app`을 `Applications`로 드래그합니다.
2. Applications 또는 Spotlight에서 Codex Gauge를 실행합니다.
3. macOS가 실행을 차단하면 `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`에서 직접 승인합니다.
4. 공식 Release와 정확한 설치 경로를 확인했지만 공식 승인으로도 열리지 않을 때만 아래 수동 대안을 사용합니다.

1. Open the DMG and drag `Codex Gauge.app` to `Applications`.
2. Launch Codex Gauge from Applications or Spotlight.
3. If macOS blocks the first launch, approve it in `System Settings → Privacy & Security → Open Anyway`.
4. Use the manual fallback below only after verifying the official Release and exact installation path, and only if the standard approval still does not open the app.

```sh
/usr/bin/xattr -dr com.apple.quarantine "/Applications/Codex Gauge.app"
/usr/bin/open "/Applications/Codex Gauge.app"
```

Codex Gauge는 Apple 배포 인증서와 공증 없이 ad-hoc signing으로 배포됩니다. 첫 명령은 앱을 설치하거나 권한을 부여하지 않고 이 앱의 quarantine 표시를 제거해 해당 앱의 quarantine 기반 Gatekeeper 최초 평가를 우회합니다. `sudo`, 더 넓은 경로, 전역 Gatekeeper 변경 또는 실행 가능한 helper를 사용하지 마세요. 프로젝트 소유 앱 코드, DMG와 배포 자동화는 이 명령을 자동 실행하지 않습니다.

Codex Gauge is distributed with ad-hoc signing and without an Apple distribution certificate or notarization. The first command does not install the app or grant permissions; it removes this app's quarantine marker and bypasses its quarantine-based first Gatekeeper assessment. Do not use `sudo`, a broader path, a global Gatekeeper change, or an executable helper. Project-owned app code, the DMG, and release automation never run this command automatically.

## 인앱 업데이트 / In-app update

새 버전 확인만으로 download나 installation이 시작되지 않습니다. 사용자가 Sparkle 표준 창에서 `업데이트`를 선택한 경우에만 HTTPS와 EdDSA로 검증한 full DMG를 사용해 앱을 교체합니다. bundled stock Sparkle은 이 승인된 표준 교체 과정에서 staged application의 quarantine metadata를 정리하고 macOS system scan을 실행할 수 있습니다. 프로젝트는 별도의 `xattr`, `spctl` 또는 Gatekeeper 전역 설정 변경을 실행하지 않습니다.

Checking for a new version never starts a download or installation. Only after the user chooses `Update` in Sparkle's standard window does the app use a full DMG verified with HTTPS and EdDSA. During this approved standard replacement process, bundled stock Sparkle may clear quarantine metadata from the staged application and invoke the macOS system scan. The project does not run a separate `xattr`, `spctl`, or global Gatekeeper change.

## 무결성 확인 / Integrity check

같이 제공되는 `CodexGauge.dmg.sha256`으로 다운로드 손상 여부를 확인할 수 있습니다. SHA-256은 Apple의 개발자 신원 확인이나 공증을 대신하지 않습니다.

The accompanying `CodexGauge.dmg.sha256` can detect download corruption. SHA-256 does not replace Apple developer identity verification or notarization.

```sh
shasum -a 256 -c CodexGauge.dmg.sha256
```

## 변경 사항 / Changes

이번 build는 배경과 드래그 안내가 있는 640×420 Finder 창, `Applications` 바로가기와 비실행 한·영 설치 안내를 DMG에 추가합니다.

This build adds a 640×420 Finder window with a guided background, the `Applications` shortcut, and a non-executable bilingual installation guide.
