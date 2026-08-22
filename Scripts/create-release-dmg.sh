#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: create-release-dmg.sh --app <path> --output <CodexGauge.dmg>" >&2
}

fail() {
    echo "release DMG creation failed: $1" >&2
    exit 1
}

application_path=""
output_path=""
stage_root=""
artifact_created=0
checksum_created=0

cleanup() {
    local status="$?"
    local leaf_name=""

    trap - EXIT
    if [ -n "$stage_root" ]; then
        leaf_name="$(basename "$stage_root")"
        case "$leaf_name" in
            .codex-gauge-dmg.*)
                if [ -d "$stage_root" ] && [ ! -L "$stage_root" ]; then
                    rm -rf -- "$stage_root"
                fi
                ;;
        esac
    fi
    if [ "$status" -ne 0 ]; then
        if [ "$checksum_created" -eq 1 ]; then
            rm -f -- "$output_path.sha256"
        fi
        if [ "$artifact_created" -eq 1 ]; then
            rm -f -- "$output_path"
        fi
    fi
    exit "$status"
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            application_path="$2"
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
[ -n "$output_path" ] || { usage; exit 64; }
[ -d "$application_path" ] || fail "application bundle is missing"
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

stage_root="$(mktemp -d "$output_directory/.codex-gauge-dmg.XXXXXX")"
stage_path="$stage_root/stage"
temporary_artifact="$stage_root/CodexGauge.dmg"
temporary_checksum="$stage_root/CodexGauge.dmg.sha256"
mkdir "$stage_path"

ditto "$application_path" "$stage_path/Codex Gauge.app"
ln -s /Applications "$stage_path/Applications"

hdiutil create \
    -srcfolder "$stage_path" \
    -volname "Codex Gauge" \
    -fs HFS+ \
    -format UDZO \
    -nospotlight \
    "$temporary_artifact"

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
