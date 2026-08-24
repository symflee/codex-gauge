# Codex Gauge macOS 배포

## 1. 결정된 배포 모델

Codex Gauge는 macOS 13 이상에서 동작하는 universal 애플리케이션을 GitHub Releases로 직접 배포한다. Apple Developer Program, Mac App Store, Developer ID 배포 서명과 Apple notarization은 사용하지 않는다.

Release application은 Apple 인증서 없이 ad-hoc code signing한다. 이 서명은 bundle의 내부 코드 무결성과 실행 형식을 검증하기 위한 것이며 개발자 신원, Gatekeeper 승인 또는 Apple notarization을 제공하지 않는다.

이 선택은 설치 형식과 macOS 신뢰 판단을 구분한다.

- 설치 형식은 일반적인 macOS DMG다.
- 사용자는 DMG에서 Codex Gauge를 `Applications`로 드래그한다.
- macOS가 최초 실행을 차단하면 사용자가 System Settings의 공식 `그래도 열기` 절차로 직접 승인한다.
- 앱, DMG, packaging automation과 Homebrew Cask는 Gatekeeper 설정을 변경하거나 quarantine을 자동 제거하지 않는다.
- 설치 안내는 공식 절차 이후 사용자가 선택할 수 있는 정확한 app-scoped 수동 대안만 제공한다.

Apple이 확인한 개발자처럼 보이게 하거나 notarization을 통과했다고 주장하지 않는다. Hardened Runtime build setting과 SHA-256 checksum도 Developer ID 또는 Apple notarization을 대신하지 않는다.

## 2. 설치 채널

### GitHub Releases

기본 설치 파일은 version tag에서 만든 `CodexGauge.dmg`다. 같은 Release에 `CodexGauge.dmg.sha256`을 첨부한다. GitHub가 자동 생성하는 `Source code.zip`과 `Source code.tar.gz`는 설치 파일이 아니며 사용자 설치 안내에서 앱 다운로드로 가리키지 않는다.

DMG의 사용자 표시 root에는 다음 세 항목만 둔다.

- Codex Gauge application bundle 하나
- `/Applications`를 가리키는 symbolic link 하나
- `docs/installation.md`와 byte-for-byte 동일한 비실행 `설치 안내 - Installation.txt` 하나

숨김 root에는 640×420 Finder 배경을 담는 `.background`와 Finder layout metadata인 `.DS_Store`만 둔다. installer script, package receipt, privileged helper와 실행 가능한 보조 설치 도구는 넣지 않는다.

### Homebrew Cask

자체 `symflee/homebrew-tap`의 Cask는 GitHub Release와 동일한 versioned DMG URL과 정확한 SHA-256을 사용한다. 설치 명령은 Cask가 실제로 공개된 뒤 다음과 같이 제공한다.

```sh
brew install --cask symflee/tap/codex-gauge
```

Cask는 `app` artifact만 사용한다. `postflight`, 임의 installer script, `xattr`, `spctl` 설정 변경과 `--no-quarantine` 안내를 사용하지 않는다. Homebrew로 설치해도 macOS의 최초 실행 승인이 필요할 수 있다.

### 제외 채널

- Mac App Store
- PKG installer
- `curl | sh` installer
- Gatekeeper 또는 System Integrity Protection 비활성화를 요구하는 설치
- quarantine을 자동 또는 넓은 범위로 제거하는 설치

## 3. 최초 실행 안내

일반 설치 순서는 다음과 같다.

1. GitHub Release에서 DMG를 다운로드한다.
2. DMG를 열고 Codex Gauge를 `Applications`로 드래그한다.
3. Applications 또는 Spotlight에서 Codex Gauge를 실행한다.
4. macOS가 확인되지 않은 개발자 경고로 실행을 차단하면 `System Settings → Privacy & Security → Open Anyway`를 선택하고 사용자 암호로 승인한다.
5. Dock 아이콘 대신 메뉴 막대 상태 항목이 나타나는지 확인한다.

한국어 안내에서는 `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`, 영어 안내에서는 macOS가 표시하는 해당 locale의 용어를 사용한다. 이 절차를 자동화하거나 사용자의 승인 없이 수행하지 않는다. macOS 버전에 따라 새 application build를 설치한 뒤 승인을 다시 요구할 수 있음을 숨기지 않는다.

공식 GitHub Release와 정확한 `/Applications/Codex Gauge.app` 설치 경로를 확인했지만 공식 절차로도 열리지 않을 때만 사용자가 다음 수동 대안을 직접 선택할 수 있다.

```sh
/usr/bin/xattr -dr com.apple.quarantine "/Applications/Codex Gauge.app"
/usr/bin/open "/Applications/Codex Gauge.app"
```

첫 명령은 앱을 설치하거나 파일 권한을 부여하지 않는다. 이미 설치된 이 앱 bundle에서 quarantine marker를 재귀적으로 제거해 이 앱의 quarantine 기반 Gatekeeper 최초 평가를 우회한다. `sudo`, 다른 앱이나 넓은 경로, `spctl --master-disable`, executable helper를 안내하지 않는다. permission error가 나면 더 강한 명령으로 재시도하지 않고 공식 GUI 절차로 돌아가거나 DMG에서 다시 설치한다. 출처가 공식 Release가 아니거나 macOS가 손상·악성 코드 가능성을 경고하면 실행하지 않는다. 전체 한·영 절차의 원본은 [설치 안내](installation.md)다.

## 4. Release artifact 계약

Release build는 다음을 검증해야 한다.

- tag `vX.Y.Z`와 `CFBundleShortVersionString` `X.Y.Z`가 정확히 일치
- `CFBundleVersion`은 이전 공개 build보다 증가
- bundle identifier는 `io.github.symflee.codex-gauge`
- 최소 시스템 버전은 macOS 13
- `LSUIElement=true`
- main executable이 `arm64`와 `x86_64`를 모두 포함
- application과 포함된 실행 코드가 ad-hoc signing과 Hardened Runtime 검증을 통과
- DMG의 visible root가 application bundle, `/Applications` symbolic link와 비실행 한·영 안내 파일로 정확히 구성됨
- DMG의 hidden root가 640×420 배경을 담는 `.background`와 Finder layout `.DS_Store`로 정확히 구성됨
- Finder 창이 640×420이고 toolbar·status bar 없이 icon view, 96pt icon과 지정 위치를 사용함
- DMG 안내 파일이 source `docs/installation.md`와 byte-for-byte 동일함
- mount한 DMG의 application metadata와 executable이 build output과 일치
- DMG SHA-256을 별도 파일로 생성하고 Release asset에 함께 첨부
- packaging 단계가 quarantine attribute를 제거하거나 Gatekeeper 설정을 변경하지 않음

SHA-256은 다운로드 손상과 Cask artifact 일치를 확인하는 값이다. Apple의 개발자 신원 확인, 악성 코드 검사 또는 notarization ticket으로 설명하지 않는다.

## 5. GitHub Release 정책

- version tag에서만 release artifact를 만든다.
- Release는 draft로 만들고 DMG, checksum과 release notes를 모두 검증한 뒤 공개한다.
- 이미 공개한 tag와 artifact는 교체하지 않고 수정이 필요하면 새 patch version을 발행한다.
- 아직 공개하지 않은 잘못된 Draft와 tag는 metadata·asset checksum을 백업하고 exact ref를 다시 확인한 뒤 사용자의 명시적 승인으로만 재생성한다.
- 일반 CI는 `contents: read`만 사용한다.
- tag release workflow만 task에 필요한 `contents: write`를 사용한다.
- Apple 인증서, notarization credential과 Apple signing secret은 사용하지 않는다.
- agent는 사용자의 별도 요청 없이 tag push 또는 GitHub Release 공개를 수행하지 않는다.

첫 release 전에는 새 macOS 사용자 계정에서 browser download, DMG mount, 배경·아이콘·안내 파일 layout, Applications drag, 공식 최초 실행 승인, 메뉴 막대 표시와 제거를 수동으로 확인한다. 별도 clean copy에서는 문서화한 app-scoped 수동 대안과 재실행도 확인한다. Apple Silicon에서 실기 검증하고 Intel 결과는 별도 runner 또는 실제 기기로 확인한다.

## 6. 업데이트 방향

자동 업데이트는 packaging과 GitHub Release 기반이 검증된 뒤 별도 task로 도입한다. 직접 self-replacement updater를 만들지 않고 Sparkle 2를 유일한 승인 후보로 사용한다.

- update archive와 appcast는 HTTPS로 제공한다.
- update archive는 Sparkle EdDSA로 서명한다.
- 공개키는 앱 bundle에 포함하고 개인키는 repository와 일반 CI에 저장하지 않는다.
- quota polling과 update schedule은 결합하지 않는다.
- 자동 확인은 하루 한 번, 자동 다운로드·설치는 기본 꺼짐으로 한다.
- telemetry와 system profiling은 사용하지 않는다.
- Developer ID가 없으므로 업데이트 뒤 Gatekeeper 승인이 다시 필요할 수 있는 동작을 실제 설치본으로 검증하고 문서화한다.

첫 안정 공개 버전에 updater가 없으면 해당 사용자는 updater가 포함된 버전까지 한 번 수동 설치해야 한다. 이를 피하기 위해 DMG·Release workflow는 draft 또는 prerelease로 먼저 검증하고, updater의 구버전→신버전 검증을 마친 뒤 첫 stable Release를 공개하는 것을 목표로 한다.
