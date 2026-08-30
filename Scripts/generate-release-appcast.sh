#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: generate-release-appcast.sh --generate-appcast-tool <path> --archive <CodexGauge.dmg> --output <appcast.xml> --tag <vX.Y.Z>" >&2
}

fail() {
    echo "release appcast generation failed: $1" >&2
    exit 1
}

generate_appcast_tool=""
archive_path=""
output_path=""
release_tag=""
stage_root=""
published=0

cleanup() {
    local status="$?"
    local leaf_name=""

    trap - EXIT
    if [ -n "$stage_root" ]; then
        leaf_name="$(basename "$stage_root")"
        case "$leaf_name" in
            .codex-gauge-appcast.*)
                if [ -d "$stage_root" ] && [ ! -L "$stage_root" ]; then
                    rm -rf -- "$stage_root"
                fi
                ;;
        esac
    fi
    if [ "$status" -ne 0 ] && [ "$published" -eq 1 ]; then
        rm -f -- "$output_path"
    fi
    exit "$status"
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --generate-appcast-tool)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            generate_appcast_tool="$2"
            shift 2
            ;;
        --archive)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            archive_path="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            output_path="$2"
            shift 2
            ;;
        --tag)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            release_tag="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[ -n "$generate_appcast_tool" ] || { usage; exit 64; }
[ -n "$archive_path" ] || { usage; exit 64; }
[ -n "$output_path" ] || { usage; exit 64; }
[ -n "$release_tag" ] || { usage; exit 64; }
printf '%s\n' "$release_tag" \
    | grep -E -q '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || fail "tag must use vX.Y.Z"
[ -f "$generate_appcast_tool" ] && [ -x "$generate_appcast_tool" ] \
    && [ ! -L "$generate_appcast_tool" ] \
    || fail "generate_appcast tool is invalid"
[ -f "$archive_path" ] && [ ! -L "$archive_path" ] \
    || fail "update archive is invalid"
[ "$(basename "$archive_path")" = "CodexGauge.dmg" ] \
    || fail "update archive must be named CodexGauge.dmg"
[ "$(basename "$output_path")" = "appcast.xml" ] \
    || fail "output must be named appcast.xml"
[ ! -e "$output_path" ] && [ ! -L "$output_path" ] \
    || fail "output already exists"

output_directory="$(dirname "$output_path")"
[ -d "$output_directory" ] && [ ! -L "$output_directory" ] \
    || fail "output directory is invalid"
output_directory="$(cd "$output_directory" && pwd)"
output_path="$output_directory/appcast.xml"
stage_root="$(mktemp -d "$output_directory/.codex-gauge-appcast.XXXXXX")"
cp "$archive_path" "$stage_root/CodexGauge.dmg"
download_url_prefix="https://github.com/symflee/codex-gauge/releases/download/$release_tag/"

if ! "$generate_appcast_tool" \
    --ed-key-file - \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    --download-url-prefix "$download_url_prefix" \
    -o "$stage_root/appcast.xml" \
    "$stage_root" \
    >/dev/null 2>&1; then
    fail "Sparkle generate_appcast failed"
fi

generated_appcast="$stage_root/appcast.xml"
[ -f "$generated_appcast" ] && [ ! -L "$generated_appcast" ] \
    || fail "Sparkle did not create appcast.xml"
grep -F -q '<!-- sparkle-signatures:' "$generated_appcast" \
    || fail "Sparkle did not sign the appcast"
grep -F -q 'sparkle:edSignature=' "$generated_appcast" \
    || fail "Sparkle did not sign the update archive"
[ ! -e "$stage_root/old_updates" ] \
    || fail "appcast generation unexpectedly created old updates"

mv -n "$generated_appcast" "$output_path"
[ ! -e "$generated_appcast" ] \
    || fail "output appeared while the appcast was being generated"
published=1

echo "PASS release appcast generation"
