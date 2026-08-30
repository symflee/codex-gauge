# Codex Gauge 설치 / Installation

Codex Gauge는 Apple 배포 인증서와 공증 없이 ad-hoc signing으로 배포됩니다. 아래 단계는 공식 GitHub Release에서 받은 `CodexGauge.dmg`에만 사용하세요.

Codex Gauge is distributed with ad-hoc signing and without an Apple distribution certificate or notarization. Follow these steps only for `CodexGauge.dmg` downloaded from the official GitHub Release.

## 일반 설치 / Standard installation

1. GitHub Release에서 `CodexGauge.dmg`와 `CodexGauge.dmg.sha256`을 다운로드합니다. GitHub의 Source code 링크는 설치 파일이 아닙니다.
2. 필요하면 두 파일이 있는 폴더에서 다음 명령으로 다운로드가 손상되지 않았는지 확인합니다.

       shasum -a 256 -c CodexGauge.dmg.sha256

3. DMG를 열고 `Codex Gauge.app`을 `Applications`로 드래그합니다.
4. Applications 또는 Spotlight에서 Codex Gauge를 실행합니다.
5. macOS가 확인되지 않은 개발자 경고로 실행을 차단하면 `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`를 선택하고 다시 확인합니다.
6. Dock 아이콘 대신 메뉴 막대에 Codex Gauge 사용량이 표시되는지 확인합니다.

1. Download `CodexGauge.dmg` and `CodexGauge.dmg.sha256` from the GitHub Release. GitHub's Source code links are not installers.
2. Optionally run the checksum command above from the folder containing both files to detect download corruption.
3. Open the DMG and drag `Codex Gauge.app` to `Applications`.
4. Launch Codex Gauge from Applications or Spotlight.
5. If macOS blocks an unidentified developer, choose `System Settings → Privacy & Security → Open Anyway`, then confirm the launch.
6. Confirm that Codex Gauge appears in the menu bar rather than the Dock.

SHA-256은 다운로드한 파일의 일치 여부만 확인합니다. Apple이 개발자 신원이나 악성 코드 부재를 확인했다는 의미가 아닙니다.

SHA-256 only checks that the downloaded artifact matches. It does not provide Apple developer identity verification or confirm that software is free of malware.

## 앱에서 업데이트 / In-app updates

`v0.1.0`에는 updater가 없습니다. 첫 updater-bearing version인 `v0.2.0` build 3이 배포되면 기존 사용자는 그 DMG를 위 절차로 한 번 직접 설치해야 합니다. 그 이후에는 앱을 실행할 때마다 새 stable version을 한 번 확인합니다. 새 version이 있으면 메뉴의 `현재 버전: vX.Y.Z (최신 vA.B.C)`를 선택해 표준 update 창을 엽니다.

`v0.1.0` does not contain an updater. When the first updater-bearing version, `v0.2.0` build 3, is released, existing users must manually install that DMG once using the steps above. After that, Codex Gauge checks once for a new stable version whenever the app launches. If one is available, choose `Current version: vX.Y.Z (latest vA.B.C)` from the menu to open the standard update window.

새 version을 찾았다는 사실만으로 download나 installation이 시작되지 않습니다. Sparkle 표준 창에서 사용자가 `업데이트`를 선택한 경우에만 full DMG를 다운로드하고 EdDSA 서명을 검증한 뒤 앱을 교체합니다. beta, delta, 단계적·강제 update와 downgrade는 제공하지 않습니다. 취소하거나 network·signature 검증이 실패하면 현재 앱을 그대로 유지합니다.

Finding a new version never starts a download or installation by itself. Only after the user chooses `Update` in Sparkle's standard window does Codex Gauge download the full DMG, verify its EdDSA signature, and replace the app. Beta, delta, phased, forced, and downgrade updates are not provided. Cancelling or failing network or signature validation leaves the current app in place.

인앱 update는 공식 GitHub DMG에서 `/Applications/Codex Gauge.app`으로 직접 설치한 경우만 지원합니다. Homebrew가 관리하는 설치의 교체와 Cask 상태 동기화는 현재 보장하지 않습니다. update 뒤 macOS가 새 build를 다시 차단하면 위의 공식 `그래도 열기` 절차를 사용하세요. 프로젝트 소유 코드와 배포 자동화는 `xattr`, `spctl` 또는 Gatekeeper 전역 설정 변경을 실행하지 않습니다. 다만 bundled stock Sparkle은 사용자가 update를 승인한 뒤 표준 교체 과정에서 staged application의 quarantine metadata를 정리하고 macOS system scan을 실행할 수 있습니다.

In-app updates are supported only for `/Applications/Codex Gauge.app` installed directly from the official GitHub DMG. Replacement and Cask-state synchronization are not currently guaranteed for Homebrew-managed installations. Use the standard `Open Anyway` procedure above if macOS blocks the new build. Project-owned code and release automation do not run `xattr`, `spctl`, or change global Gatekeeper settings. After the user approves an update, bundled stock Sparkle may clear quarantine metadata from the staged application and invoke the macOS system scan as part of its standard replacement process.

## 공식 승인으로도 열리지 않을 때 / Manual fallback

공식 GitHub Release에서 직접 받은 DMG를 사용했고 앱이 정확히 `/Applications/Codex Gauge.app`에 설치되어 있음을 확인한 경우에만 아래 대안을 사용하세요. 먼저 위의 macOS 공식 승인 절차를 시도해야 합니다.

Use this fallback only after confirming that the DMG came directly from the official GitHub Release and that the app is installed exactly at `/Applications/Codex Gauge.app`. Try the standard macOS approval flow above first.

    /usr/bin/xattr -dr com.apple.quarantine "/Applications/Codex Gauge.app"
    /usr/bin/open "/Applications/Codex Gauge.app"

첫 명령은 앱을 복사하거나 설치하지 않고 파일 권한도 부여하지 않습니다. 이미 설치된 이 앱 bundle에서 `com.apple.quarantine` 표시를 재귀적으로 제거하여 이 앱에 대한 quarantine 기반 Gatekeeper 최초 평가를 우회합니다. 두 번째 명령은 앱을 다시 실행합니다.

The first command does not copy or install the app and does not grant file permissions. It recursively removes the `com.apple.quarantine` marker from this installed app bundle, bypassing the quarantine-based first Gatekeeper assessment for this app. The second command launches the app again.

- 명령 앞에 `sudo`를 붙이지 마세요.
- `Permission denied` 또는 `Operation not permitted`가 나오면 더 강한 명령이나 더 넓은 경로를 사용하지 마세요. 공식 macOS 승인 절차로 돌아가거나 DMG에서 앱을 다시 설치하세요.
- 다른 앱, `/Applications` 전체, 홈 폴더 또는 시스템 전체의 quarantine을 제거하지 마세요.
- `spctl --master-disable`처럼 Gatekeeper를 전역으로 변경하지 마세요. 이 프로젝트는 실행 가능한 설치 helper를 제공하지 않습니다.
- 출처가 공식 Release가 아니거나 macOS가 앱 손상 또는 악성 코드 가능성을 경고하면 이 대안을 사용하지 말고 파일을 삭제하세요.

- Do not prefix either command with `sudo`.
- If you see `Permission denied` or `Operation not permitted`, do not retry with stronger commands or broader paths. Return to the standard macOS approval flow or reinstall the app from the DMG.
- Do not remove quarantine from other apps, all of `/Applications`, your home folder, or the system.
- Do not change Gatekeeper globally with commands such as `spctl --master-disable`. This project does not provide an executable installation helper.
- If the file did not come from the official Release, or macOS warns that it is damaged or may contain malware, do not use this fallback; delete the file.

프로젝트 소유 Codex Gauge 코드, DMG와 배포 자동화는 이 명령을 자동 실행하지 않습니다. 사용자가 위 위험을 이해하고 해당 앱 하나에 대해 직접 선택하는 수동 절차입니다.

Project-owned Codex Gauge code, the DMG, and release automation never execute this command automatically. It is a manual, app-scoped choice for a user who understands the risk above.
