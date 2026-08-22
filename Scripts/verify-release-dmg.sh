#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: verify-release-dmg.sh --dmg <path> --checksum <path> [--source-app <path>] --version <X.Y.Z> --build <number>" >&2
}

fail() {
    echo "release DMG verification failed: $1" >&2
    exit 1
}

dmg_path=""
checksum_path=""
source_application=""
expected_version=""
expected_build=""
mount_root=""
mount_path=""
mounted=0

cleanup() {
    local status="$?"
    local leaf_name=""

    trap - EXIT
    if [ "$mounted" -eq 1 ]; then
        if ! hdiutil detach "$mount_path" >/dev/null; then
            echo "release DMG verification cleanup failed: could not detach volume" >&2
            status=1
        fi
    fi
    if [ -n "$mount_root" ]; then
        leaf_name="$(basename "$mount_root")"
        case "$leaf_name" in
            codex-gauge-mount.*)
                if [ -d "$mount_path" ]; then
                    rmdir "$mount_path" 2>/dev/null || true
                fi
                if [ -d "$mount_root" ]; then
                    rmdir "$mount_root" 2>/dev/null || true
                fi
                ;;
        esac
    fi
    exit "$status"
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dmg)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            dmg_path="$2"
            shift 2
            ;;
        --checksum)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            checksum_path="$2"
            shift 2
            ;;
        --source-app)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            source_application="$2"
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

[ -n "$dmg_path" ] || { usage; exit 64; }
[ -n "$checksum_path" ] || { usage; exit 64; }
[ -n "$expected_version" ] || { usage; exit 64; }
[ -n "$expected_build" ] || { usage; exit 64; }
[ -f "$dmg_path" ] || fail "DMG is missing"
[ -f "$checksum_path" ] || fail "checksum is missing"
if [ -n "$source_application" ]; then
    [ -d "$source_application" ] || fail "source application is missing"
fi

checksum_line_count="$(wc -l < "$checksum_path" | tr -d '[:space:]')"
[ "$checksum_line_count" = "1" ] || fail "checksum must contain one line"
checksum_hash="$(awk 'NR == 1 { print $1 }' "$checksum_path")"
checksum_name="$(awk 'NR == 1 { print $2 }' "$checksum_path")"
printf '%s\n' "$checksum_hash" | grep -E -q '^[0-9a-f]{64}$' \
    || fail "checksum is malformed"
[ "$checksum_name" = "$(basename "$dmg_path")" ] \
    || fail "checksum references a different artifact"
actual_checksum="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
[ "$actual_checksum" = "$checksum_hash" ] || fail "checksum does not match"

hdiutil verify "$dmg_path" >/dev/null

mount_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-mount.XXXXXX")"
mount_path="$mount_root/volume"
mkdir "$mount_path"
hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$mount_path" \
    "$dmg_path" \
    >/dev/null
mounted=1

entry_count="$(find "$mount_path" -mindepth 1 -maxdepth 1 -print \
    | wc -l \
    | tr -d '[:space:]')"
[ "$entry_count" = "2" ] || fail "DMG root must contain exactly two entries"

mounted_application="$mount_path/Codex Gauge.app"
applications_link="$mount_path/Applications"
[ -d "$mounted_application" ] || fail "Codex Gauge application is missing"
[ ! -L "$mounted_application" ] \
    || fail "Codex Gauge application must be a bundle copy"
[ -L "$applications_link" ] || fail "Applications link is missing"
[ "$(readlink "$applications_link")" = "/Applications" ] \
    || fail "Applications link has the wrong target"

script_directory="$(cd "$(dirname "$0")" && pwd)"
"$script_directory/verify-release-app.sh" \
    --app "$mounted_application" \
    --version "$expected_version" \
    --build "$expected_build"

if [ -n "$source_application" ]; then
    "$script_directory/verify-release-app.sh" \
        --app "$source_application" \
        --version "$expected_version" \
        --build "$expected_build"
    source_executable="$(plutil -extract CFBundleExecutable raw -o - \
        "$source_application/Contents/Info.plist")"
    mounted_executable="$(plutil -extract CFBundleExecutable raw -o - \
        "$mounted_application/Contents/Info.plist")"
    cmp -s \
        "$source_application/Contents/Info.plist" \
        "$mounted_application/Contents/Info.plist" \
        || fail "mounted application metadata differs from the build output"
    cmp -s \
        "$source_application/Contents/MacOS/$source_executable" \
        "$mounted_application/Contents/MacOS/$mounted_executable" \
        || fail "mounted executable differs from the build output"
fi

hdiutil detach "$mount_path" >/dev/null
mounted=0

echo "PASS release DMG verification"
