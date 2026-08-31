#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: build-release-dmg.sh --output-directory <path> --version <X.Y.Z> --build <number> [--sparkle-public-ed-key <base64>] --allow-local-release-effects" >&2
}

fail() {
    echo "release build failed: $1" >&2
    exit 1
}

output_directory=""
expected_version=""
expected_build=""
sparkle_public_ed_key="${SPARKLE_PUBLIC_ED_KEY:-}"
derived_data_root=""
release_stage_root=""
published_artifact=""
artifact_published=0
checksum_published=0
allows_local_release_effects=0

cleanup() {
    local status="$?"
    local leaf_name=""

    trap - EXIT
    if [ -n "$derived_data_root" ]; then
        leaf_name="$(basename "$derived_data_root")"
        case "$leaf_name" in
            codex-gauge-derived-data.*)
                if [ -d "$derived_data_root" ] && [ ! -L "$derived_data_root" ]; then
                    rm -rf -- "$derived_data_root"
                fi
                ;;
        esac
    fi
    if [ -n "$release_stage_root" ]; then
        leaf_name="$(basename "$release_stage_root")"
        case "$leaf_name" in
            .codex-gauge-release.*)
                if [ -d "$release_stage_root" ] && [ ! -L "$release_stage_root" ]; then
                    rm -rf -- "$release_stage_root"
                fi
                ;;
        esac
    fi
    if [ "$status" -ne 0 ] && [ -n "$published_artifact" ]; then
        if [ "$checksum_published" -eq 1 ]; then
            rm -f -- "$published_artifact.sha256"
        fi
        if [ "$artifact_published" -eq 1 ]; then
            rm -f -- "$published_artifact"
        fi
    fi
    exit "$status"
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-directory)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            output_directory="$2"
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
            sparkle_public_ed_key="$2"
            shift 2
            ;;
        --allow-local-release-effects)
            allows_local_release_effects=1
            shift
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[ -n "$output_directory" ] || { usage; exit 64; }
printf '%s\n' "$expected_version" \
    | grep -E -q '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "version must use X.Y.Z"
printf '%s\n' "$expected_build" | grep -E -q '^[1-9][0-9]*$' \
    || fail "build must be a positive integer"
ruby -rbase64 -e '
  key = Base64.strict_decode64(ARGV.fetch(0))
  exit(key.bytesize == 32 ? 0 : 1)
' "$sparkle_public_ed_key" >/dev/null 2>&1 \
    || fail "Sparkle public EdDSA key must be 32-byte base64"
[ "$allows_local_release_effects" -eq 1 ] \
    || fail "pass --allow-local-release-effects to build a DMG"
export CODEX_GAUGE_LOCAL_RELEASE_EFFECTS_ALLOWED=1

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
application_entitlements="$repository_root/App/CodexGauge/CodexGauge.entitlements"
[ -f "$application_entitlements" ] && [ ! -L "$application_entitlements" ] \
    || fail "canonical application entitlements are missing"
plutil -lint "$application_entitlements" >/dev/null \
    || fail "canonical application entitlements are invalid"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
published_artifact="$output_directory/CodexGauge.dmg"
[ ! -e "$published_artifact" ] && [ ! -L "$published_artifact" ] \
    || fail "output already exists"
[ ! -e "$published_artifact.sha256" ] && [ ! -L "$published_artifact.sha256" ] \
    || fail "checksum output already exists"

derived_data_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-derived-data.XXXXXX")"
release_stage_root="$(mktemp -d "$output_directory/.codex-gauge-release.XXXXXX")"
artifact_path="$release_stage_root/CodexGauge.dmg"

xcodebuild build \
    -project "$repository_root/CodexGauge.xcodeproj" \
    -scheme CodexGauge \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_root" \
    -disableAutomaticPackageResolution \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM= \
    "SPARKLE_PUBLIC_ED_KEY=$sparkle_public_ed_key" \
    ONLY_ACTIVE_ARCH=NO \
    "ARCHS=arm64 x86_64"

application_path="$derived_data_root/Build/Products/Release/CodexGauge.app"
[ -d "$application_path" ] || fail "Xcode application output is missing"

third_party_notices_source="$repository_root/THIRD_PARTY_NOTICES.md"
third_party_notices_destination="$application_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
[ -f "$third_party_notices_source" ] && [ ! -L "$third_party_notices_source" ] \
    || fail "canonical third-party notices are missing"
if [ -e "$third_party_notices_destination" ] \
    || [ -L "$third_party_notices_destination" ]; then
    [ -f "$third_party_notices_destination" ] \
        && [ ! -L "$third_party_notices_destination" ] \
        && cmp -s \
            "$third_party_notices_source" \
            "$third_party_notices_destination" \
        || fail "bundled third-party notices are invalid"
else
    cp "$third_party_notices_source" "$third_party_notices_destination"
fi

sparkle_framework="$application_path/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle_framework/Versions/B"
sparkle_xpc_services="$sparkle_version/XPCServices"
sparkle_xpc_services_link="$sparkle_framework/XPCServices"
sparkle_autoupdate="$sparkle_version/Autoupdate"
sparkle_updater="$sparkle_version/Updater.app"
[ -d "$sparkle_framework" ] && [ ! -L "$sparkle_framework" ] \
    || fail "Sparkle.framework is missing from the application"
[ -d "$sparkle_xpc_services" ] && [ ! -L "$sparkle_xpc_services" ] \
    || fail "Sparkle XPC service directory has an unexpected structure"
[ -L "$sparkle_xpc_services_link" ] \
    && [ "$(readlink "$sparkle_xpc_services_link")" = "Versions/Current/XPCServices" ] \
    || fail "Sparkle XPC service link has an unexpected structure"
[ -x "$sparkle_autoupdate" ] \
    || fail "Sparkle Autoupdate helper is missing"
[ -d "$sparkle_updater" ] && [ ! -L "$sparkle_updater" ] \
    || fail "Sparkle Updater is missing"

rm -r -- "$sparkle_xpc_services"
rm -- "$sparkle_xpc_services_link"
[ ! -e "$sparkle_xpc_services" ] && [ ! -L "$sparkle_xpc_services" ] \
    || fail "Sparkle XPC services were not removed"
[ ! -e "$sparkle_xpc_services_link" ] \
    && [ ! -L "$sparkle_xpc_services_link" ] \
    || fail "Sparkle XPC service link was not removed"

codesign --force --sign - --options runtime "$sparkle_autoupdate"
codesign --force --sign - --options runtime "$sparkle_updater"
codesign \
    --force \
    --sign - \
    --options runtime \
    --preserve-metadata=identifier \
    "$sparkle_framework"
codesign \
    --force \
    --sign - \
    --options runtime \
    --preserve-metadata=identifier,requirements \
    --entitlements "$application_entitlements" \
    "$application_path"

"$script_directory/verify-release-app.sh" \
    --app "$application_path" \
    --version "$expected_version" \
    --build "$expected_build" \
    --sparkle-public-ed-key "$sparkle_public_ed_key" \
    --expected-third-party-notices "$third_party_notices_source"

"$script_directory/create-release-dmg.sh" \
    --app "$application_path" \
    --background "$repository_root/Distribution/DMG/background.png" \
    --guide "$repository_root/docs/installation.md" \
    --output "$artifact_path" \
    --allow-local-release-effects
"$script_directory/verify-release-dmg.sh" \
    --dmg "$artifact_path" \
    --checksum "$artifact_path.sha256" \
    --source-app "$application_path" \
    --expected-guide "$repository_root/docs/installation.md" \
    --sparkle-public-ed-key "$sparkle_public_ed_key" \
    --expected-third-party-notices "$third_party_notices_source" \
    --version "$expected_version" \
    --build "$expected_build" \
    --allow-local-release-effects

mv -n "$artifact_path" "$published_artifact"
[ ! -e "$artifact_path" ] \
    || fail "output appeared while the release was being verified"
artifact_published=1

mv -n "$artifact_path.sha256" "$published_artifact.sha256"
[ ! -e "$artifact_path.sha256" ] \
    || fail "checksum output appeared while the release was being verified"
checksum_published=1

echo "PASS release build"
