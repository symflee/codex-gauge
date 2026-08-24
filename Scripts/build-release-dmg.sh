#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: build-release-dmg.sh --output-directory <path> --version <X.Y.Z> --build <number>" >&2
}

fail() {
    echo "release build failed: $1" >&2
    exit 1
}

output_directory=""
expected_version=""
expected_build=""
derived_data_root=""
release_stage_root=""
published_artifact=""
artifact_published=0
checksum_published=0

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

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
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
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM= \
    ONLY_ACTIVE_ARCH=NO \
    "ARCHS=arm64 x86_64"

application_path="$derived_data_root/Build/Products/Release/CodexGauge.app"
[ -d "$application_path" ] || fail "Xcode application output is missing"

"$script_directory/verify-release-app.sh" \
    --app "$application_path" \
    --version "$expected_version" \
    --build "$expected_build"
"$script_directory/create-release-dmg.sh" \
    --app "$application_path" \
    --background "$repository_root/Distribution/DMG/background.png" \
    --guide "$repository_root/docs/installation.md" \
    --output "$artifact_path"
"$script_directory/verify-release-dmg.sh" \
    --dmg "$artifact_path" \
    --checksum "$artifact_path.sha256" \
    --source-app "$application_path" \
    --expected-guide "$repository_root/docs/installation.md" \
    --version "$expected_version" \
    --build "$expected_build"

mv -n "$artifact_path" "$published_artifact"
[ ! -e "$artifact_path" ] \
    || fail "output appeared while the release was being verified"
artifact_published=1

mv -n "$artifact_path.sha256" "$published_artifact.sha256"
[ ! -e "$artifact_path.sha256" ] \
    || fail "checksum output appeared while the release was being verified"
checksum_published=1

echo "PASS release build"
