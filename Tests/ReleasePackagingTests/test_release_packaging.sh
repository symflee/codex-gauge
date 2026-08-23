#!/bin/bash

set -euo pipefail

test_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$test_directory/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-release-tests.XXXXXX")"

cleanup() {
    local leaf_name

    leaf_name="$(basename "$test_root")"
    case "$leaf_name" in
        codex-gauge-release-tests.*)
            if [ -d "$test_root" ] && [ ! -L "$test_root" ]; then
                rm -rf -- "$test_root"
            fi
            ;;
    esac
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

create_fixture_application() {
    local application_path="$1"
    local contents_path="$application_path/Contents"
    local executable_path="$contents_path/MacOS/CodexGauge"
    local plist_path="$contents_path/Info.plist"
    local source_path="$test_root/main.c"

    mkdir -p "$contents_path/MacOS"
    printf '%s\n' 'int main(void) { return 0; }' > "$source_path"
    xcrun clang \
        -arch arm64 \
        -arch x86_64 \
        -mmacosx-version-min=13.0 \
        "$source_path" \
        -o "$executable_path"

    plutil -create xml1 "$plist_path"
    plutil -insert CFBundleExecutable -string CodexGauge "$plist_path"
    plutil -insert CFBundleIdentifier -string io.github.symflee.codex-gauge "$plist_path"
    plutil -insert CFBundleDisplayName -string "Codex Gauge" "$plist_path"
    plutil -insert CFBundleName -string "Codex Gauge" "$plist_path"
    plutil -insert CFBundlePackageType -string APPL "$plist_path"
    plutil -insert CFBundleShortVersionString -string 0.1.0 "$plist_path"
    plutil -insert CFBundleVersion -string 1 "$plist_path"
    plutil -insert LSMinimumSystemVersion -string 13.0 "$plist_path"
    plutil -insert LSUIElement -bool true "$plist_path"
    mkdir -p "$contents_path/Resources/en.lproj"
    mkdir -p "$contents_path/Resources/ko.lproj"
    printf '%s\n' '"fixture" = "Fixture";' > "$contents_path/Resources/en.lproj/Localizable.strings"
    printf '%s\n' '"fixture" = "픽스처";' > "$contents_path/Resources/ko.lproj/Localizable.strings"
    codesign --force --sign - --options runtime "$application_path"
}

copy_and_sign_fixture() {
    local destination="$1"

    ditto "$fixture_application" "$destination"
    shift
    "$@" "$destination"
    codesign --force --sign - --options runtime "$destination" >/dev/null
}

set_invalid_bundle_identifier() {
    local application_path="$1"

    plutil -replace CFBundleIdentifier \
        -string io.github.symflee.invalid \
        "$application_path/Contents/Info.plist"
}

remove_korean_localization() {
    local application_path="$1"

    rm "$application_path/Contents/Resources/ko.lproj/Localizable.strings"
}

replace_fixture_executable() {
    local application_path="$1"
    local source_path="$test_root/different-main.c"

    printf '%s\n' 'int main(void) { return 1; }' > "$source_path"
    xcrun clang \
        -arch arm64 \
        -arch x86_64 \
        -mmacosx-version-min=13.0 \
        "$source_path" \
        -o "$application_path/Contents/MacOS/CodexGauge"
}

trap cleanup EXIT

create_script="$repository_root/Scripts/create-release-dmg.sh"
build_script="$repository_root/Scripts/build-release-dmg.sh"
verify_application_script="$repository_root/Scripts/verify-release-app.sh"
verify_dmg_script="$repository_root/Scripts/verify-release-dmg.sh"

test -x "$create_script" || fail "missing executable create-release-dmg.sh"
test -x "$build_script" || fail "missing executable build-release-dmg.sh"
test -x "$verify_application_script" || fail "missing executable verify-release-app.sh"
test -x "$verify_dmg_script" || fail "missing executable verify-release-dmg.sh"

bash -n "$create_script"
bash -n "$build_script"
bash -n "$verify_application_script"
bash -n "$verify_dmg_script"

if grep -q 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES' "$build_script"; then
    fail "Xcode package builds cannot combine suppressed warnings with warnings as errors"
fi

if grep -E '\b(xattr|spctl)\b|no-quarantine|--noqtn|--norsrc|--noextattr|DITTONORSRC|COPYFILE_DISABLE' \
    "$create_script" \
    "$build_script" \
    "$verify_application_script" \
    "$verify_dmg_script"; then
    fail "release scripts must not bypass Gatekeeper or quarantine"
fi

fixture_application="$test_root/Fixture.app"
create_fixture_application "$fixture_application"

"$verify_application_script" \
    --app "$fixture_application" \
    --version 0.1.0 \
    --build 1

expect_failure "$verify_application_script" \
    --app "$fixture_application" \
    --version 0.1.1 \
    --build 1

invalid_bundle_application="$test_root/InvalidBundle.app"
copy_and_sign_fixture \
    "$invalid_bundle_application" \
    set_invalid_bundle_identifier
expect_failure "$verify_application_script" \
    --app "$invalid_bundle_application" \
    --version 0.1.0 \
    --build 1

missing_localization_application="$test_root/MissingLocalization.app"
copy_and_sign_fixture \
    "$missing_localization_application" \
    remove_korean_localization
expect_failure "$verify_application_script" \
    --app "$missing_localization_application" \
    --version 0.1.0 \
    --build 1

artifact_path="$test_root/CodexGauge.dmg"
"$create_script" \
    --app "$fixture_application" \
    --output "$artifact_path"

test -f "$artifact_path" || fail "DMG was not created"
test -f "$artifact_path.sha256" || fail "checksum was not created"
if find "$test_root" -maxdepth 1 -name '.codex-gauge-dmg.*' -print -quit \
    | grep -q .; then
    fail "DMG staging directory was not cleaned"
fi

expect_failure "$create_script" \
    --app "$fixture_application" \
    --output "$artifact_path"

"$verify_dmg_script" \
    --dmg "$artifact_path" \
    --checksum "$artifact_path.sha256" \
    --source-app "$fixture_application" \
    --version 0.1.0 \
    --build 1

different_application="$test_root/Different.app"
copy_and_sign_fixture \
    "$different_application" \
    replace_fixture_executable
expect_failure "$verify_dmg_script" \
    --dmg "$artifact_path" \
    --checksum "$artifact_path.sha256" \
    --source-app "$different_application" \
    --version 0.1.0 \
    --build 1

invalid_checksum="$test_root/invalid.sha256"
printf '%064d  CodexGauge.dmg\n' 0 > "$invalid_checksum"
expect_failure "$verify_dmg_script" \
    --dmg "$artifact_path" \
    --checksum "$invalid_checksum" \
    --version 0.1.0 \
    --build 1

symlink_stage="$test_root/symlink-stage"
symlink_artifact="$test_root/SymlinkApp.dmg"
mkdir "$symlink_stage"
ln -s "$fixture_application" "$symlink_stage/Codex Gauge.app"
ln -s /Applications "$symlink_stage/Applications"
hdiutil create \
    -srcfolder "$symlink_stage" \
    -volname "Codex Gauge Invalid" \
    -fs HFS+ \
    -format UDZO \
    -nospotlight \
    "$symlink_artifact" \
    >/dev/null
symlink_checksum="$(shasum -a 256 "$symlink_artifact" | awk '{print $1}')"
printf '%s  %s\n' \
    "$symlink_checksum" \
    "$(basename "$symlink_artifact")" \
    > "$symlink_artifact.sha256"
expect_failure "$verify_dmg_script" \
    --dmg "$symlink_artifact" \
    --checksum "$symlink_artifact.sha256" \
    --version 0.1.0 \
    --build 1

echo "PASS release packaging scripts"
