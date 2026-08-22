#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: verify-release-app.sh --app <path> --version <X.Y.Z> --build <number>" >&2
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

application_path=""
expected_version=""
expected_build=""

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

architectures="$(lipo -archs "$executable_path")"
case "$architectures" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *) fail "main executable is not universal" ;;
esac

resources_path="$application_path/Contents/Resources"
[ -d "$resources_path" ] || fail "Resources directory is missing"
find "$resources_path" -path '*/en.lproj/Localizable.strings' -print -quit \
    | grep -q . || fail "English localization is missing"
find "$resources_path" -path '*/ko.lproj/Localizable.strings' -print -quit \
    | grep -q . || fail "Korean localization is missing"

codesign --verify --deep --strict --verbose=2 "$application_path"
for architecture in arm64 x86_64; do
    signature_details="$(codesign \
        --display \
        --architecture "$architecture" \
        --verbose=3 \
        "$application_path" \
        2>&1)"
    grep -q '^Signature=adhoc$' <<< "$signature_details" \
        || fail "$architecture slice is not ad-hoc signed"
    grep -E -q '^CodeDirectory .*runtime' <<< "$signature_details" \
        || fail "$architecture slice does not enable Hardened Runtime"
done

echo "PASS release application verification"
