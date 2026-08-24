#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: create-release-dmg.sh --app <path> --background <png> --guide <path> --output <CodexGauge.dmg>" >&2
}

fail() {
    echo "release DMG creation failed: $1" >&2
    exit 1
}

application_path=""
background_path=""
guide_path=""
output_path=""
stage_root=""
mount_path=""
mounted=0
detach_failed=0
layout_process_id=0
artifact_created=0
checksum_created=0

detach_mounted_image() {
    if [ "$mounted" -ne 1 ]; then
        return 0
    fi
    if ! hdiutil detach "$mount_path" >/dev/null; then
        detach_failed=1
        return 1
    fi
    mounted=0
}

remove_stage_root() {
    local leaf_name=""

    [ -n "$stage_root" ] || return 0
    leaf_name="$(basename "$stage_root")"
    case "$leaf_name" in
        .codex-gauge-dmg.*)
            if [ -d "$stage_root" ] && [ ! -L "$stage_root" ]; then
                rm -rf -- "$stage_root"
            fi
            ;;
    esac
}

remove_partial_outputs() {
    if [ "$checksum_created" -eq 1 ]; then
        rm -f -- "$output_path.sha256"
    fi
    if [ "$artifact_created" -eq 1 ]; then
        rm -f -- "$output_path"
    fi
}

cleanup() {
    local status="$?"
    local stage_safe_to_remove=1

    trap - EXIT
    if [ "$layout_process_id" -gt 0 ] \
        && kill -0 "$layout_process_id" 2>/dev/null; then
        kill "$layout_process_id" 2>/dev/null || true
        wait "$layout_process_id" 2>/dev/null || true
    fi
    if [ "$mounted" -eq 1 ] && [ "$detach_failed" -eq 1 ]; then
        stage_safe_to_remove=0
        status=1
    elif ! detach_mounted_image; then
        echo "release DMG creation cleanup failed: could not detach volume" >&2
        stage_safe_to_remove=0
        status=1
    fi
    if [ "$stage_safe_to_remove" -eq 1 ]; then
        remove_stage_root
    fi
    if [ "$status" -ne 0 ]; then
        remove_partial_outputs
    fi
    exit "$status"
}

configure_finder_layout() {
    local deadline=$((SECONDS + 30))

    osascript "$layout_script" "$layout_volume_name" "$mount_path" &
    layout_process_id=$!
    while kill -0 "$layout_process_id" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            kill "$layout_process_id" 2>/dev/null || true
            wait "$layout_process_id" 2>/dev/null || true
            layout_process_id=0
            fail "Finder layout timed out after 30 seconds"
        fi
        sleep 1
    done
    if ! wait "$layout_process_id"; then
        layout_process_id=0
        fail "Finder layout could not be applied"
    fi
    layout_process_id=0
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            application_path="$2"
            shift 2
            ;;
        --background)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            background_path="$2"
            shift 2
            ;;
        --guide)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            guide_path="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            output_path="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[ -n "$application_path" ] || { usage; exit 64; }
[ -n "$background_path" ] || { usage; exit 64; }
[ -n "$guide_path" ] || { usage; exit 64; }
[ -n "$output_path" ] || { usage; exit 64; }
[ -d "$application_path" ] || fail "application bundle is missing"
[ -f "$background_path" ] && [ ! -L "$background_path" ] \
    || fail "background must be a regular file"
[ -f "$guide_path" ] && [ ! -L "$guide_path" ] \
    || fail "installation guide must be a regular file"
[ ! -x "$guide_path" ] || fail "installation guide must not be executable"
ruby -e 'data = File.binread(ARGV.fetch(0)); exit(data.force_encoding(Encoding::UTF_8).valid_encoding? ? 0 : 1)' \
    "$guide_path" \
    || fail "installation guide must be valid UTF-8"

background_width="$(sips -g pixelWidth "$background_path" \
    | awk '/pixelWidth:/ { print $2 }')"
background_height="$(sips -g pixelHeight "$background_path" \
    | awk '/pixelHeight:/ { print $2 }')"
background_format="$(sips -g format "$background_path" \
    | awk '/format:/ { print $2 }')"
[ "$background_format" = "png" ] || fail "background format must be PNG"
[ "$background_width" = "640" ] || fail "background width must be 640"
[ "$background_height" = "420" ] || fail "background height must be 420"

case "$output_path" in
    *.dmg) ;;
    *) fail "output must use the .dmg extension" ;;
esac
[ "$(basename "$output_path")" = "CodexGauge.dmg" ] \
    || fail "output must be named CodexGauge.dmg"

output_directory="$(dirname "$output_path")"
[ -d "$output_directory" ] || fail "output directory is missing"
output_directory="$(cd "$output_directory" && pwd)"
output_path="$output_directory/CodexGauge.dmg"
[ ! -e "$output_path" ] && [ ! -L "$output_path" ] \
    || fail "output already exists"
[ ! -e "$output_path.sha256" ] && [ ! -L "$output_path.sha256" ] \
    || fail "checksum output already exists"

script_directory="$(cd "$(dirname "$0")" && pwd)"
layout_script="$script_directory/configure-release-dmg.applescript"
[ -f "$layout_script" ] || fail "Finder layout script is missing"

stage_root="$(mktemp -d "$output_directory/.codex-gauge-dmg.XXXXXX")"
stage_path="$stage_root/stage"
mount_path="$stage_root/mount"
writable_artifact="$stage_root/CodexGauge-writable.dmg"
temporary_artifact="$stage_root/CodexGauge.dmg"
temporary_checksum="$stage_root/CodexGauge.dmg.sha256"
layout_volume_name="Codex Gauge Layout $$"
mkdir "$stage_path" "$mount_path"

ditto "$application_path" "$stage_path/Codex Gauge.app"
ln -s /Applications "$stage_path/Applications"
cp "$guide_path" "$stage_path/설치 안내 - Installation.txt"
chmod 0644 "$stage_path/설치 안내 - Installation.txt"
mkdir "$stage_path/.background"
cp "$background_path" "$stage_path/.background/background.png"
chmod 0644 "$stage_path/.background/background.png"

hdiutil create \
    -srcfolder "$stage_path" \
    -volname "$layout_volume_name" \
    -fs HFS+ \
    -format UDRW \
    -nospotlight \
    "$writable_artifact" \
    >/dev/null

hdiutil attach \
    -readwrite \
    -nobrowse \
    -noautoopen \
    -mountpoint "$mount_path" \
    "$writable_artifact" \
    >/dev/null
mounted=1

mounted_volume_name="$(diskutil info -plist "$mount_path" \
    | plutil -extract VolumeName raw -o - -)"
[ "$mounted_volume_name" = "$layout_volume_name" ] \
    || fail "mounted volume name does not match the layout image"

configure_finder_layout
[ -s "$mount_path/.DS_Store" ] \
    || fail "Finder layout metadata was not created"
diskutil renameVolume "$mount_path" "Codex Gauge" >/dev/null
detach_mounted_image

hdiutil convert \
    "$writable_artifact" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$temporary_artifact" \
    >/dev/null

checksum="$(shasum -a 256 "$temporary_artifact" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$output_path")" \
    > "$temporary_checksum"

mv -n "$temporary_artifact" "$output_path"
[ ! -e "$temporary_artifact" ] \
    || fail "output appeared while the DMG was being created"
artifact_created=1

mv -n "$temporary_checksum" "$output_path.sha256"
[ ! -e "$temporary_checksum" ] \
    || fail "checksum output appeared while the DMG was being created"
checksum_created=1

echo "PASS release DMG creation"
