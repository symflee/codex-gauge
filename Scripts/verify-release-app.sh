#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: verify-release-app.sh --app <path> --version <X.Y.Z> --build <number> [--sparkle-public-ed-key <base64>] [--expected-third-party-notices <path>]" >&2
}

fail() {
    echo "release application verification failed: $1" >&2
    exit 1
}

read_plist_value() {
    local key="$1"
    local plist_path="$2"

    plutil -extract "$key" raw -o - "$plist_path"
}

require_value() {
    local actual="$1"
    local expected="$2"
    local label="$3"

    if [ "$actual" != "$expected" ]; then
        fail "$label does not match the release contract"
    fi
}

require_absent_plist_key() {
    local key="$1"
    local plist_path="$2"

    if plutil -extract "$key" raw -o - "$plist_path" >/dev/null 2>&1; then
        fail "$key must be absent from the release application"
    fi
}

require_universal_executable() {
    local executable_path="$1"
    local label="$2"
    local architectures=""

    [ -x "$executable_path" ] || fail "$label is missing"
    architectures="$(lipo -archs "$executable_path")"
    case "$architectures" in
        "arm64 x86_64"|"x86_64 arm64") ;;
        *) fail "$label is not universal" ;;
    esac
}

verify_adhoc_hardened_signature() {
    local code_path="$1"
    local label="$2"
    local architecture=""
    local signature_details=""

    codesign --verify --strict --verbose=2 "$code_path"
    for architecture in arm64 x86_64; do
        signature_details="$(codesign \
            --display \
            --architecture "$architecture" \
            --verbose=3 \
            "$code_path" \
            2>&1)"
        grep -q '^Signature=adhoc$' <<< "$signature_details" \
            || fail "$label $architecture slice is not ad-hoc signed"
        grep -E -q '^CodeDirectory .*runtime' <<< "$signature_details" \
            || fail "$label $architecture slice lacks Hardened Runtime"
    done
}

read_effective_entitlements() {
    local code_path="$1"
    local architecture="$2"
    local output=""

    if ! output="$(codesign \
        --display \
        --architecture "$architecture" \
        --xml \
        --entitlements - \
        "$code_path" \
        2>/dev/null)"; then
        fail "effective entitlements could not be inspected"
    fi
    if [ -z "$output" ]; then
        printf '{}'
        return
    fi
    printf '%s' "$output" | plutil -convert json -o - -- - \
        || fail "effective entitlements are not a property list"
}

verify_application_entitlements() {
    local code_path="$1"
    local architecture=""
    local entitlements=""

    for architecture in arm64 x86_64; do
        entitlements="$(read_effective_entitlements "$code_path" "$architecture")"
        ruby -rjson -e '
          expected = {"com.apple.security.cs.disable-library-validation" => true}
          exit(JSON.parse(STDIN.read) == expected ? 0 : 1)
        ' <<< "$entitlements" \
            || fail "application entitlements do not match the release contract ($architecture)"
    done
}

verify_empty_entitlements() {
    local code_path="$1"
    local label="$2"
    local architecture=""
    local entitlements=""

    for architecture in arm64 x86_64; do
        entitlements="$(read_effective_entitlements "$code_path" "$architecture")"
        ruby -rjson -e 'exit(JSON.parse(STDIN.read).empty? ? 0 : 1)' \
            <<< "$entitlements" \
            || fail "$label must not contain entitlements ($architecture)"
    done
}

application_path=""
expected_version=""
expected_build=""
expected_public_ed_key=""
expected_third_party_notices=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            application_path="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            expected_version="$2"
            shift 2
            ;;
        --build)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            expected_build="$2"
            shift 2
            ;;
        --sparkle-public-ed-key)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            expected_public_ed_key="$2"
            shift 2
            ;;
        --expected-third-party-notices)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            expected_third_party_notices="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[ -n "$application_path" ] || { usage; exit 64; }
[ -n "$expected_version" ] || { usage; exit 64; }
[ -n "$expected_build" ] || { usage; exit 64; }
[ -d "$application_path" ] || fail "application bundle is missing"
if [ -n "$expected_third_party_notices" ]; then
    [ -f "$expected_third_party_notices" ] \
        && [ ! -L "$expected_third_party_notices" ] \
        || fail "canonical third-party notices are missing"
fi

plist_path="$application_path/Contents/Info.plist"
[ -f "$plist_path" ] || fail "Info.plist is missing"

executable_name="$(read_plist_value CFBundleExecutable "$plist_path")"
[ -n "$executable_name" ] || fail "CFBundleExecutable is empty"
executable_path="$application_path/Contents/MacOS/$executable_name"
[ -x "$executable_path" ] || fail "main executable is missing"

require_value \
    "$(read_plist_value CFBundleIdentifier "$plist_path")" \
    "io.github.symflee.codex-gauge" \
    "bundle identifier"
require_value \
    "$(read_plist_value CFBundleDisplayName "$plist_path")" \
    "Codex Gauge" \
    "display name"
require_value \
    "$(read_plist_value CFBundlePackageType "$plist_path")" \
    "APPL" \
    "bundle package type"
require_value \
    "$(read_plist_value CFBundleShortVersionString "$plist_path")" \
    "$expected_version" \
    "marketing version"
require_value \
    "$(read_plist_value CFBundleVersion "$plist_path")" \
    "$expected_build" \
    "build version"
require_value \
    "$(read_plist_value LSMinimumSystemVersion "$plist_path")" \
    "13.0" \
    "minimum macOS version"
require_value \
    "$(read_plist_value LSUIElement "$plist_path")" \
    "true" \
    "LSUIElement"

require_universal_executable "$executable_path" "main executable"

resources_path="$application_path/Contents/Resources"
[ -d "$resources_path" ] || fail "Resources directory is missing"
find "$resources_path" -path '*/en.lproj/Localizable.strings' -print -quit \
    | grep -q . || fail "English localization is missing"
find "$resources_path" -path '*/ko.lproj/Localizable.strings' -print -quit \
    | grep -q . || fail "Korean localization is missing"

public_ed_key="$(read_plist_value SUPublicEDKey "$plist_path")"
ruby -rbase64 -e '
  key = Base64.strict_decode64(ARGV.fetch(0))
  exit(key.bytesize == 32 ? 0 : 1)
' "$public_ed_key" >/dev/null 2>&1 \
    || fail "SUPublicEDKey is not a 32-byte base64 key"
if [ -n "$expected_public_ed_key" ]; then
    require_value "$public_ed_key" "$expected_public_ed_key" "Sparkle public key"
fi
require_value \
    "$(read_plist_value SUFeedURL "$plist_path")" \
    "https://github.com/symflee/codex-gauge/releases/latest/download/appcast.xml" \
    "Sparkle feed URL"
require_value \
    "$(read_plist_value SUEnableAutomaticChecks "$plist_path")" \
    "false" \
    "scheduled update checks"
require_absent_plist_key "SUScheduledCheckInterval" "$plist_path"
require_value \
    "$(read_plist_value SUAutomaticallyUpdate "$plist_path")" \
    "false" \
    "automatic update installation"
require_value \
    "$(read_plist_value SUAllowsAutomaticUpdates "$plist_path")" \
    "false" \
    "automatic update permission"
require_value \
    "$(read_plist_value SUEnableSystemProfiling "$plist_path")" \
    "false" \
    "Sparkle system profiling"
require_value \
    "$(read_plist_value SUShowReleaseNotes "$plist_path")" \
    "false" \
    "Sparkle release notes"
require_value \
    "$(read_plist_value SUVerifyUpdateBeforeExtraction "$plist_path")" \
    "true" \
    "pre-extraction update verification"
require_value \
    "$(read_plist_value SURequireSignedFeed "$plist_path")" \
    "true" \
    "signed feed requirement"
require_value \
    "$(read_plist_value SUSignedFeedFailureExpirationInterval "$plist_path")" \
    "0" \
    "signed feed failure expiration"
installer_service="$(plutil -extract SUEnableInstallerLauncherService raw -o - \
    "$plist_path" 2>/dev/null || true)"
downloader_service="$(plutil -extract SUEnableDownloaderService raw -o - \
    "$plist_path" 2>/dev/null || true)"
[ "$installer_service" != "true" ] \
    || fail "sandbox-only Installer XPC service is enabled"
[ "$downloader_service" != "true" ] \
    || fail "sandbox-only Downloader XPC service is enabled"

third_party_notices="$resources_path/THIRD_PARTY_NOTICES.md"
[ -f "$third_party_notices" ] && [ ! -L "$third_party_notices" ] \
    || fail "third-party notices are missing"
grep -F -q 'Sparkle' "$third_party_notices" \
    || fail "third-party notices do not identify Sparkle"
grep -F -q 'MIT License' "$third_party_notices" \
    || fail "third-party notices omit the Sparkle license"
if [ -n "$expected_third_party_notices" ]; then
    cmp -s "$expected_third_party_notices" "$third_party_notices" \
        || fail "bundled third-party notices differ from the canonical file"
fi

sparkle_framework="$application_path/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle_framework/Versions/B"
sparkle_binary="$sparkle_version/Sparkle"
sparkle_autoupdate="$sparkle_version/Autoupdate"
sparkle_updater="$sparkle_version/Updater.app"
sparkle_updater_binary="$sparkle_updater/Contents/MacOS/Updater"
[ -d "$sparkle_framework" ] && [ ! -L "$sparkle_framework" ] \
    || fail "Sparkle.framework is missing"
[ -d "$sparkle_version" ] && [ ! -L "$sparkle_version" ] \
    || fail "Sparkle framework version B is missing"
[ -L "$sparkle_framework/Versions/Current" ] \
    && [ "$(readlink "$sparkle_framework/Versions/Current")" = "B" ] \
    || fail "Sparkle framework current version is invalid"
[ ! -e "$sparkle_version/XPCServices" ] \
    && [ ! -L "$sparkle_version/XPCServices" ] \
    || fail "unused Sparkle XPC services remain in the release"
[ ! -e "$sparkle_framework/XPCServices" ] \
    && [ ! -L "$sparkle_framework/XPCServices" ] \
    || fail "unused Sparkle XPC service link remains in the release"
require_universal_executable "$sparkle_binary" "Sparkle framework binary"
require_universal_executable "$sparkle_autoupdate" "Sparkle Autoupdate"
[ -d "$sparkle_updater" ] && [ ! -L "$sparkle_updater" ] \
    || fail "Sparkle Updater is missing"
require_universal_executable "$sparkle_updater_binary" "Sparkle Updater executable"

verify_adhoc_hardened_signature "$sparkle_autoupdate" "Sparkle Autoupdate"
verify_adhoc_hardened_signature "$sparkle_updater" "Sparkle Updater"
verify_adhoc_hardened_signature "$sparkle_framework" "Sparkle framework"
verify_adhoc_hardened_signature "$application_path" "application"
verify_empty_entitlements "$sparkle_autoupdate" "Sparkle Autoupdate"
verify_empty_entitlements "$sparkle_updater" "Sparkle Updater"
verify_empty_entitlements "$sparkle_framework" "Sparkle framework"
verify_application_entitlements "$application_path"

echo "PASS release application verification"
