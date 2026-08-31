#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: verify-release-dmg.sh --dmg <path> --checksum <path> [--source-app <path>] [--expected-guide <path>] [--sparkle-public-ed-key <base64>] [--expected-third-party-notices <path>] --version <X.Y.Z> --build <number> --allow-local-release-effects" >&2
}

fail() {
    echo "release DMG verification failed: $1" >&2
    exit 1
}

dmg_path=""
checksum_path=""
source_application=""
expected_guide=""
expected_version=""
expected_build=""
expected_public_ed_key=""
expected_third_party_notices=""
mount_root=""
mount_path=""
mounted=0
layout_process_id=0
allows_local_release_effects=0

cleanup() {
    local status="$?"
    local leaf_name=""

    trap - EXIT
    if [ "$layout_process_id" -gt 0 ] \
        && kill -0 "$layout_process_id" 2>/dev/null; then
        kill "$layout_process_id" 2>/dev/null || true
        wait "$layout_process_id" 2>/dev/null || true
    fi
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

verify_finder_layout() {
    local deadline=$((SECONDS + 30))

    osascript "$layout_verification_script" "$mount_path" &
    layout_process_id=$!
    while kill -0 "$layout_process_id" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            kill "$layout_process_id" 2>/dev/null || true
            wait "$layout_process_id" 2>/dev/null || true
            layout_process_id=0
            fail "Finder layout verification timed out after 30 seconds"
        fi
        sleep 1
    done
    if ! wait "$layout_process_id"; then
        layout_process_id=0
        fail "Finder layout does not match the release contract"
    fi
    layout_process_id=0
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
        --expected-guide)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            expected_guide="$2"
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

[ -n "$dmg_path" ] || { usage; exit 64; }
[ -n "$checksum_path" ] || { usage; exit 64; }
[ -n "$expected_version" ] || { usage; exit 64; }
[ -n "$expected_build" ] || { usage; exit 64; }
[ -f "$dmg_path" ] || fail "DMG is missing"
[ -f "$checksum_path" ] || fail "checksum is missing"
if [ -n "$source_application" ]; then
    [ -d "$source_application" ] || fail "source application is missing"
fi
if [ -n "$expected_guide" ]; then
    [ -f "$expected_guide" ] && [ ! -L "$expected_guide" ] \
        || fail "expected installation guide is missing"
fi
if [ -n "$expected_third_party_notices" ]; then
    [ -f "$expected_third_party_notices" ] \
        && [ ! -L "$expected_third_party_notices" ] \
        || fail "expected third-party notices are missing"
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
layout_verification_script="$script_directory/verify-release-dmg-layout.applescript"
[ -f "$layout_verification_script" ] \
    || fail "Finder layout verification script is missing"

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
[ "$allows_local_release_effects" -eq 1 ] \
    || [ "${CODEX_GAUGE_LOCAL_RELEASE_EFFECTS_ALLOWED:-}" = "1" ] \
    || fail "pass --allow-local-release-effects to mount and inspect a DMG"

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

volume_name="$(diskutil info -plist "$mount_path" \
    | plutil -extract VolumeName raw -o - -)"
[ "$volume_name" = "Codex Gauge" ] \
    || fail "DMG volume name does not match the release contract"

visible_entries="$(find "$mount_path" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name '.*' \
    -exec basename {} \; \
    | ruby -e 'STDIN.each_line { |line| puts line.chomp.unicode_normalize(:nfc) }' \
    | LC_ALL=C sort)"
expected_visible_entries="$(printf '%s\n' \
    Applications \
    'Codex Gauge.app' \
    '설치 안내 - Installation.txt' \
    | LC_ALL=C sort)"
[ "$visible_entries" = "$expected_visible_entries" ] \
    || fail "DMG visible root entries do not match the release contract"

hidden_entries="$(find "$mount_path" \
    -mindepth 1 \
    -maxdepth 1 \
    -name '.*' \
    -exec basename {} \; \
    | LC_ALL=C sort)"
expected_hidden_entries="$(printf '%s\n' .DS_Store .background | LC_ALL=C sort)"
[ "$hidden_entries" = "$expected_hidden_entries" ] \
    || fail "DMG hidden root entries do not match the release contract"

mounted_application="$mount_path/Codex Gauge.app"
applications_link="$mount_path/Applications"
mounted_guide="$mount_path/설치 안내 - Installation.txt"
background_directory="$mount_path/.background"
mounted_background="$background_directory/background.png"
finder_layout="$mount_path/.DS_Store"
[ -d "$mounted_application" ] || fail "Codex Gauge application is missing"
[ ! -L "$mounted_application" ] \
    || fail "Codex Gauge application must be a bundle copy"
[ -L "$applications_link" ] || fail "Applications link is missing"
[ "$(readlink "$applications_link")" = "/Applications" ] \
    || fail "Applications link has the wrong target"
[ -f "$mounted_guide" ] && [ ! -L "$mounted_guide" ] \
    || fail "installation guide must be a regular file"
[ ! -x "$mounted_guide" ] || fail "installation guide must not be executable"
ruby -e 'data = File.binread(ARGV.fetch(0)); exit(data.force_encoding(Encoding::UTF_8).valid_encoding? ? 0 : 1)' \
    "$mounted_guide" \
    || fail "installation guide must be valid UTF-8"

[ -d "$background_directory" ] && [ ! -L "$background_directory" ] \
    || fail "DMG background directory is invalid"
background_entries="$(find "$background_directory" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec basename {} \; \
    | LC_ALL=C sort)"
[ "$background_entries" = "background.png" ] \
    || fail "DMG background directory must contain one PNG"
[ -f "$mounted_background" ] && [ ! -L "$mounted_background" ] \
    || fail "DMG background must be a regular file"
background_width="$(sips -g pixelWidth "$mounted_background" \
    | awk '/pixelWidth:/ { print $2 }')"
background_height="$(sips -g pixelHeight "$mounted_background" \
    | awk '/pixelHeight:/ { print $2 }')"
background_format="$(sips -g format "$mounted_background" \
    | awk '/format:/ { print $2 }')"
[ "$background_format" = "png" ] || fail "DMG background format must be PNG"
[ "$background_width" = "640" ] || fail "DMG background width must be 640"
[ "$background_height" = "420" ] || fail "DMG background height must be 420"

[ -f "$finder_layout" ] && [ ! -L "$finder_layout" ] \
    || fail "Finder layout metadata is missing"
[ -s "$finder_layout" ] || fail "Finder layout metadata is empty"
[ ! -x "$finder_layout" ] || fail "Finder layout metadata must not be executable"
verify_finder_layout

guide_korean_line="$(grep -n -m 1 -F \
    '시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기' \
    "$mounted_guide" \
    | cut -d: -f1 \
    || true)"
guide_fallback_line="$(grep -n -m 1 -F \
    '/usr/bin/xattr -dr com.apple.quarantine "/Applications/Codex Gauge.app"' \
    "$mounted_guide" \
    | cut -d: -f1 \
    || true)"
[ -n "$guide_korean_line" ] || fail "installation guide lacks Open Anyway"
[ -n "$guide_fallback_line" ] || fail "installation guide lacks fallback command"
[ "$guide_korean_line" -lt "$guide_fallback_line" ] \
    || fail "installation guide must present Open Anyway first"
grep -F -q 'Codex Gauge 설치 / Installation' "$mounted_guide" \
    || fail "installation guide is not bilingual"
grep -F -q '/usr/bin/open "/Applications/Codex Gauge.app"' "$mounted_guide" \
    || fail "installation guide lacks the relaunch command"
grep -F -q 'Gatekeeper 최초 평가를 우회합니다' "$mounted_guide" \
    || fail "installation guide lacks the quarantine risk explanation"
if ! ruby - "$mounted_guide" <<'RUBY'
path = ARGV.fetch(0)
lines = File.readlines(path, chomp: true).map(&:strip)
xattr_command = '/usr/bin/xattr -dr com.apple.quarantine "/Applications/Codex Gauge.app"'
open_command = '/usr/bin/open "/Applications/Codex Gauge.app"'
exit(1) unless lines.count(xattr_command) == 1
exit(1) unless lines.count(open_command) == 1
exit(1) unless lines.index(xattr_command) < lines.index(open_command)

lines.each do |line|
  next if line == xattr_command || line == open_command
  exit(1) if line.match?(/\A(?:sudo\s+)?(?:\/usr\/bin\/)?xattr(?:\s|\z)/)
  exit(1) if line.match?(/\A(?:sudo\s+)?(?:\/usr\/sbin\/)?spctl(?:\s|\z)/)
  exit(1) if line.match?(/\A(?:sudo\s+)?(?:\/usr\/bin\/)?open(?:\s|\z)/)
end
RUBY
then
    fail "installation guide contains commands outside the approved fallback"
fi
if grep -E -q '^[[:space:]]*sudo[[:space:]]+(/usr/bin/)?xattr|^[[:space:]]*(sudo[[:space:]]+)?(/usr/sbin/)?spctl[[:space:]].*--master-disable' \
    "$mounted_guide"; then
    fail "installation guide contains a prohibited broad security command"
fi
if [ -n "$expected_guide" ]; then
    cmp -s "$expected_guide" "$mounted_guide" \
        || fail "installation guide differs from the canonical document"
fi

application_verification_arguments=(
    --version "$expected_version"
    --build "$expected_build"
)
if [ -n "$expected_public_ed_key" ]; then
    application_verification_arguments+=(
        --sparkle-public-ed-key "$expected_public_ed_key"
    )
fi
if [ -n "$expected_third_party_notices" ]; then
    application_verification_arguments+=(
        --expected-third-party-notices "$expected_third_party_notices"
    )
fi

"$script_directory/verify-release-app.sh" \
    --app "$mounted_application" \
    "${application_verification_arguments[@]}"

if [ -n "$source_application" ]; then
    "$script_directory/verify-release-app.sh" \
        --app "$source_application" \
        "${application_verification_arguments[@]}"
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
