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

expect_failure_containing() {
    local expected_message="$1"
    local output=""
    local status=0

    shift
    set +e
    output="$("$@" 2>&1)"
    status="$?"
    set -e
    [ "$status" -ne 0 ] || fail "command unexpectedly succeeded: $*"
    printf '%s\n' "$output" | grep -F -q "$expected_message" \
        || fail "failure did not report '$expected_message': $*; output: $output"
}

prepare_release_stage() {
    local stage_path="$1"

    mkdir "$stage_path"
    ditto "$fixture_application" "$stage_path/Codex Gauge.app"
    ln -s /Applications "$stage_path/Applications"
    cp "$guide_source" "$stage_path/설치 안내 - Installation.txt"
    chmod 0644 "$stage_path/설치 안내 - Installation.txt"
    mkdir "$stage_path/.background"
    cp "$background_source" "$stage_path/.background/background.png"
}

create_stage_artifact() {
    local stage_path="$1"
    local artifact_path="$2"
    local layout_mode="${3:-valid}"
    local artifact_checksum=""
    local layout_mount_root=""
    local layout_mount_path=""
    local writable_artifact=""
    local fixture_volume_name="Codex Gauge Test $$"

    layout_mount_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-fixture-mount.XXXXXX")"
    layout_mount_path="$layout_mount_root/volume"
    writable_artifact="$layout_mount_root/writable.dmg"
    hdiutil create \
        -srcfolder "$stage_path" \
        -volname "$fixture_volume_name" \
        -fs HFS+ \
        -format UDRW \
        -nospotlight \
        "$writable_artifact" \
        >/dev/null
    mkdir "$layout_mount_path"
    hdiutil attach \
        -readwrite \
        -nobrowse \
        -noautoopen \
        -mountpoint "$layout_mount_path" \
        "$writable_artifact" \
        >/dev/null
    if [ "$layout_mode" != "skip" ]; then
        if ! osascript \
            "$configure_layout_script" \
            "$fixture_volume_name" \
            "$layout_mount_path"; then
            hdiutil detach "$layout_mount_path" >/dev/null || true
            fail "could not configure a synthetic release fixture"
        fi
    fi
    if [ "$layout_mode" = "invalid" ]; then
        if ! osascript "$invalidate_layout_script" "$layout_mount_path"; then
            hdiutil detach "$layout_mount_path" >/dev/null || true
            fail "could not invalidate a synthetic release fixture"
        fi
    fi
    if [ "$layout_mode" = "relocated" ]; then
        if ! osascript "$relocate_layout_script" "$layout_mount_path"; then
            hdiutil detach "$layout_mount_path" >/dev/null || true
            fail "could not relocate a synthetic release fixture"
        fi
    fi
    if [ "$layout_mode" = "resized" ]; then
        if ! osascript "$resize_layout_script" "$layout_mount_path"; then
            hdiutil detach "$layout_mount_path" >/dev/null || true
            fail "could not resize a synthetic release fixture"
        fi
    fi
    diskutil renameVolume "$layout_mount_path" "Codex Gauge" >/dev/null
    if ! hdiutil detach "$layout_mount_path" >/dev/null; then
        fail "could not detach a synthetic release fixture"
    fi
    rmdir "$layout_mount_path"
    hdiutil convert \
        "$writable_artifact" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$artifact_path" \
        >/dev/null
    rm -- "$writable_artifact"
    rmdir "$layout_mount_root"
    artifact_checksum="$(shasum -a 256 "$artifact_path" | awk '{print $1}')"
    printf '%s  %s\n' \
        "$artifact_checksum" \
        "$(basename "$artifact_path")" \
        > "$artifact_path.sha256"
}

expect_create_failure() {
    local case_name="$1"
    local background_path="$2"
    local guide_path="$3"
    local output_directory="$test_root/create-failure-$case_name"

    mkdir "$output_directory"
    expect_failure "$create_script" \
        --app "$fixture_application" \
        --background "$background_path" \
        --guide "$guide_path" \
        --output "$output_directory/CodexGauge.dmg"
    test ! -e "$output_directory/CodexGauge.dmg" \
        || fail "failed creation left a DMG for $case_name"
    test ! -e "$output_directory/CodexGauge.dmg.sha256" \
        || fail "failed creation left a checksum for $case_name"
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
configure_layout_script="$repository_root/Scripts/configure-release-dmg.applescript"
verify_layout_script="$repository_root/Scripts/verify-release-dmg-layout.applescript"
invalidate_layout_script="$test_directory/set-invalid-dmg-layout.applescript"
relocate_layout_script="$test_directory/relocate-dmg-window.applescript"
resize_layout_script="$test_directory/resize-dmg-window.applescript"
verify_background_safe_zone="$test_directory/verify-background-safe-zone.swift"
background_generator="$repository_root/Scripts/generate-dmg-background.swift"
guide_source="$repository_root/docs/installation.md"
background_source="$repository_root/Distribution/DMG/background.png"

test -x "$create_script" || fail "missing executable create-release-dmg.sh"
test -x "$build_script" || fail "missing executable build-release-dmg.sh"
test -x "$verify_application_script" || fail "missing executable verify-release-app.sh"
test -x "$verify_dmg_script" || fail "missing executable verify-release-dmg.sh"
test -f "$configure_layout_script" || fail "missing Finder layout script"
test -f "$verify_layout_script" || fail "missing Finder layout verification script"
test -f "$invalidate_layout_script" || fail "missing invalid Finder layout fixture"
test -f "$relocate_layout_script" || fail "missing relocated Finder layout fixture"
test -f "$resize_layout_script" || fail "missing resized Finder layout fixture"
test -f "$verify_background_safe_zone" || fail "missing background safe-zone verifier"
test -f "$background_generator" || fail "missing DMG background generator"
test -f "$guide_source" || fail "missing installation guide"
test -f "$background_source" || fail "missing DMG background"
grep -F -q 'remove_transient_volume_metadata' "$create_script" \
    || fail "DMG creation does not remove transient Finder metadata"
grep -E -q '\.fseventsd.*\.Spotlight-V100.*\.TemporaryItems.*\.Trashes' \
    "$create_script" \
    || fail "DMG creation lacks the bounded transient metadata allowlist"

bash -n "$create_script"
bash -n "$build_script"
bash -n "$verify_application_script"
bash -n "$verify_dmg_script"
osacompile -o "$test_root/configure-release-dmg.scpt" \
    "$configure_layout_script"
osacompile -o "$test_root/verify-release-dmg-layout.scpt" \
    "$verify_layout_script"
osacompile -o "$test_root/set-invalid-dmg-layout.scpt" \
    "$invalidate_layout_script"
osacompile -o "$test_root/relocate-dmg-window.scpt" \
    "$relocate_layout_script"
osacompile -o "$test_root/resize-dmg-window.scpt" \
    "$resize_layout_script"

background_width="$(sips -g pixelWidth "$background_source" \
    | awk '/pixelWidth:/ { print $2 }')"
background_height="$(sips -g pixelHeight "$background_source" \
    | awk '/pixelHeight:/ { print $2 }')"
[ "$background_width" = "640" ] || fail "DMG background width must be 640"
[ "$background_height" = "420" ] || fail "DMG background height must be 420"
generated_background="$test_root/generated-background.png"
xcrun swift \
    -module-cache-path "$test_root/swift-module-cache" \
    "$background_generator" \
    "$generated_background"
cmp -s "$generated_background" "$background_source" \
    || fail "committed DMG background differs from its deterministic generator"
xcrun swift \
    -module-cache-path "$test_root/swift-module-cache" \
    "$verify_background_safe_zone" \
    "$background_source"
grep -F -q 'Applications로 드래그 / Drag to Applications' \
    "$background_generator" \
    || fail "DMG background lacks the drag instruction"
grep -F -q '실행이 차단되면 설치 안내를 여세요' "$background_generator" \
    || fail "DMG background lacks the Korean guide instruction"
grep -F -q 'If blocked, open the guide' "$background_generator" \
    || fail "DMG background lacks the English guide instruction"

grep -F -q 'Codex Gauge 설치 / Installation' "$guide_source" \
    || fail "installation guide is not bilingual"
grep -F -q '시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기' \
    "$guide_source" \
    || fail "installation guide lacks the primary macOS approval path"
grep -F -q '/usr/bin/xattr -dr com.apple.quarantine "/Applications/Codex Gauge.app"' \
    "$guide_source" \
    || fail "installation guide lacks the scoped quarantine fallback"
grep -F -q '/usr/bin/open "/Applications/Codex Gauge.app"' "$guide_source" \
    || fail "installation guide lacks the relaunch command"
if grep -E -q '^[[:space:]]*sudo[[:space:]]+(/usr/bin/)?xattr|^[[:space:]]*(sudo[[:space:]]+)?(/usr/sbin/)?spctl[[:space:]].*--master-disable' \
    "$guide_source"; then
    fail "installation guide contains a prohibited broad security command"
fi

if grep -q 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES' "$build_script"; then
    fail "Xcode package builds cannot combine suppressed warnings with warnings as errors"
fi

if grep -E '^[[:space:]]*(sudo[[:space:]]+)?(/usr/bin/)?(xattr|spctl)([[:space:]]|$)|do shell script.*(xattr|spctl)|no-quarantine|--noqtn|--norsrc|--noextattr|DITTONORSRC|COPYFILE_DISABLE' \
    "$create_script" \
    "$build_script" \
    "$verify_application_script" \
    "$verify_dmg_script" \
    "$configure_layout_script" \
    "$verify_layout_script"; then
    fail "release scripts must not bypass Gatekeeper or quarantine"
fi

fixture_application="$test_root/Fixture.app"
create_fixture_application "$fixture_application"

missing_guide="$test_root/missing-installation-guide.md"
missing_background="$test_root/missing-background.png"
executable_guide="$test_root/executable-installation-guide.md"
guide_symlink="$test_root/installation-guide-symlink.md"
wrong_background="$test_root/wrong-background.png"
wrong_background_format="$test_root/wrong-background-format.png"
cp "$guide_source" "$executable_guide"
chmod 0755 "$executable_guide"
ln -s "$guide_source" "$guide_symlink"
sips -z 32 32 "$background_source" --out "$wrong_background" >/dev/null
sips -s format jpeg "$background_source" \
    --out "$wrong_background_format" \
    >/dev/null

expect_create_failure missing-guide "$background_source" "$missing_guide"
expect_create_failure missing-background "$missing_background" "$guide_source"
expect_create_failure executable-guide "$background_source" "$executable_guide"
expect_create_failure guide-symlink "$background_source" "$guide_symlink"
expect_create_failure wrong-background "$wrong_background" "$guide_source"
expect_create_failure wrong-background-format \
    "$wrong_background_format" \
    "$guide_source"

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
    --background "$background_source" \
    --guide "$guide_source" \
    --output "$artifact_path"

test -f "$artifact_path" || fail "DMG was not created"
test -f "$artifact_path.sha256" || fail "checksum was not created"
if find "$test_root" -maxdepth 1 -name '.codex-gauge-dmg.*' -print -quit \
    | grep -q .; then
    fail "DMG staging directory was not cleaned"
fi

expect_failure "$create_script" \
    --app "$fixture_application" \
    --background "$background_source" \
    --guide "$guide_source" \
    --output "$artifact_path"

"$verify_dmg_script" \
    --dmg "$artifact_path" \
    --checksum "$artifact_path.sha256" \
    --source-app "$fixture_application" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

relocated_layout_stage="$test_root/relocated-layout-stage"
relocated_layout_artifact="$test_root/RelocatedLayout.dmg"
prepare_release_stage "$relocated_layout_stage"
create_stage_artifact \
    "$relocated_layout_stage" \
    "$relocated_layout_artifact" \
    relocated
"$verify_dmg_script" \
    --dmg "$relocated_layout_artifact" \
    --checksum "$relocated_layout_artifact.sha256" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

resized_layout_stage="$test_root/resized-layout-stage"
resized_layout_artifact="$test_root/ResizedLayout.dmg"
prepare_release_stage "$resized_layout_stage"
create_stage_artifact \
    "$resized_layout_stage" \
    "$resized_layout_artifact" \
    resized
expect_failure_containing "Finder layout does not match" \
    "$verify_dmg_script" \
    --dmg "$resized_layout_artifact" \
    --checksum "$resized_layout_artifact.sha256" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

invalid_layout_stage="$test_root/invalid-layout-stage"
invalid_layout_artifact="$test_root/InvalidLayout.dmg"
prepare_release_stage "$invalid_layout_stage"
create_stage_artifact \
    "$invalid_layout_stage" \
    "$invalid_layout_artifact" \
    invalid
expect_failure_containing "Finder layout does not match" \
    "$verify_dmg_script" \
    --dmg "$invalid_layout_artifact" \
    --checksum "$invalid_layout_artifact.sha256" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

different_application="$test_root/Different.app"
copy_and_sign_fixture \
    "$different_application" \
    replace_fixture_executable
expect_failure_containing "mounted executable differs" \
    "$verify_dmg_script" \
    --dmg "$artifact_path" \
    --checksum "$artifact_path.sha256" \
    --source-app "$different_application" \
    --version 0.1.0 \
    --build 1

invalid_checksum="$test_root/invalid.sha256"
printf '%064d  CodexGauge.dmg\n' 0 > "$invalid_checksum"
expect_failure_containing "checksum does not match" \
    "$verify_dmg_script" \
    --dmg "$artifact_path" \
    --checksum "$invalid_checksum" \
    --version 0.1.0 \
    --build 1

symlink_stage="$test_root/symlink-stage"
symlink_artifact="$test_root/SymlinkApp.dmg"
prepare_release_stage "$symlink_stage"
test -d "$symlink_stage/Codex Gauge.app" \
    && test ! -L "$symlink_stage/Codex Gauge.app" \
    || fail "fixture application copy is unsafe to replace"
rm -r -- "$symlink_stage/Codex Gauge.app"
ln -s "$fixture_application" "$symlink_stage/Codex Gauge.app"
create_stage_artifact "$symlink_stage" "$symlink_artifact"
expect_failure_containing "must be a bundle copy" \
    "$verify_dmg_script" \
    --dmg "$symlink_artifact" \
    --checksum "$symlink_artifact.sha256" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

wrong_link_stage="$test_root/wrong-link-stage"
wrong_link_artifact="$test_root/WrongApplicationsLink.dmg"
prepare_release_stage "$wrong_link_stage"
rm "$wrong_link_stage/Applications"
ln -s /tmp "$wrong_link_stage/Applications"
create_stage_artifact "$wrong_link_stage" "$wrong_link_artifact"
expect_failure_containing "Applications link has the wrong target" \
    "$verify_dmg_script" \
    --dmg "$wrong_link_artifact" \
    --checksum "$wrong_link_artifact.sha256" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

executable_guide_stage="$test_root/executable-guide-stage"
executable_guide_artifact="$test_root/ExecutableGuide.dmg"
prepare_release_stage "$executable_guide_stage"
chmod 0755 "$executable_guide_stage/설치 안내 - Installation.txt"
create_stage_artifact "$executable_guide_stage" "$executable_guide_artifact"
expect_failure_containing "installation guide must not be executable" \
    "$verify_dmg_script" \
    --dmg "$executable_guide_artifact" \
    --checksum "$executable_guide_artifact.sha256" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

tampered_guide_stage="$test_root/tampered-guide-stage"
tampered_guide_artifact="$test_root/TamperedGuide.dmg"
prepare_release_stage "$tampered_guide_stage"
printf '%s\n' 'tampered' >> "$tampered_guide_stage/설치 안내 - Installation.txt"
create_stage_artifact "$tampered_guide_stage" "$tampered_guide_artifact"
expect_failure_containing "installation guide differs from the canonical document" \
    "$verify_dmg_script" \
    --dmg "$tampered_guide_artifact" \
    --checksum "$tampered_guide_artifact.sha256" \
    --expected-guide "$guide_source" \
    --version 0.1.0 \
    --build 1

extra_visible_stage="$test_root/extra-visible-stage"
extra_visible_artifact="$test_root/ExtraVisible.dmg"
prepare_release_stage "$extra_visible_stage"
printf '%s\n' 'unexpected' > "$extra_visible_stage/Unexpected.txt"
create_stage_artifact "$extra_visible_stage" "$extra_visible_artifact"
expect_failure_containing "visible root entries do not match" \
    "$verify_dmg_script" \
    --dmg "$extra_visible_artifact" \
    --checksum "$extra_visible_artifact.sha256" \
    --version 0.1.0 \
    --build 1

extra_hidden_stage="$test_root/extra-hidden-stage"
extra_hidden_artifact="$test_root/ExtraHidden.dmg"
prepare_release_stage "$extra_hidden_stage"
printf '%s\n' 'unexpected' > "$extra_hidden_stage/.unexpected"
create_stage_artifact "$extra_hidden_stage" "$extra_hidden_artifact"
expect_failure_containing "hidden root entries do not match" \
    "$verify_dmg_script" \
    --dmg "$extra_hidden_artifact" \
    --checksum "$extra_hidden_artifact.sha256" \
    --version 0.1.0 \
    --build 1

missing_mounted_guide_stage="$test_root/missing-mounted-guide-stage"
missing_mounted_guide_artifact="$test_root/MissingMountedGuide.dmg"
prepare_release_stage "$missing_mounted_guide_stage"
rm "$missing_mounted_guide_stage/설치 안내 - Installation.txt"
create_stage_artifact \
    "$missing_mounted_guide_stage" \
    "$missing_mounted_guide_artifact" \
    skip
expect_failure_containing "visible root entries do not match" \
    "$verify_dmg_script" \
    --dmg "$missing_mounted_guide_artifact" \
    --checksum "$missing_mounted_guide_artifact.sha256" \
    --version 0.1.0 \
    --build 1

symlink_mounted_guide_stage="$test_root/symlink-mounted-guide-stage"
symlink_mounted_guide_artifact="$test_root/SymlinkMountedGuide.dmg"
prepare_release_stage "$symlink_mounted_guide_stage"
rm "$symlink_mounted_guide_stage/설치 안내 - Installation.txt"
ln -s "$guide_source" \
    "$symlink_mounted_guide_stage/설치 안내 - Installation.txt"
create_stage_artifact \
    "$symlink_mounted_guide_stage" \
    "$symlink_mounted_guide_artifact"
expect_failure_containing "installation guide must be a regular file" \
    "$verify_dmg_script" \
    --dmg "$symlink_mounted_guide_artifact" \
    --checksum "$symlink_mounted_guide_artifact.sha256" \
    --version 0.1.0 \
    --build 1

broad_command_guide_stage="$test_root/broad-command-guide-stage"
broad_command_guide_artifact="$test_root/BroadCommandGuide.dmg"
prepare_release_stage "$broad_command_guide_stage"
printf '%s\n' \
    '/usr/bin/xattr -dr com.apple.quarantine "/Applications"' \
    >> "$broad_command_guide_stage/설치 안내 - Installation.txt"
create_stage_artifact \
    "$broad_command_guide_stage" \
    "$broad_command_guide_artifact"
expect_failure_containing "commands outside the approved fallback" \
    "$verify_dmg_script" \
    --dmg "$broad_command_guide_artifact" \
    --checksum "$broad_command_guide_artifact.sha256" \
    --version 0.1.0 \
    --build 1

reversed_command_guide_stage="$test_root/reversed-command-guide-stage"
reversed_command_guide_artifact="$test_root/ReversedCommandGuide.dmg"
prepare_release_stage "$reversed_command_guide_stage"
ruby -e '
  path = ARGV.fetch(0)
  text = File.binread(path)
  xattr = %q{/usr/bin/xattr -dr com.apple.quarantine "/Applications/Codex Gauge.app"}
  open = %q{/usr/bin/open "/Applications/Codex Gauge.app"}
  File.binwrite(path, text.sub("    #{xattr}\n    #{open}", "    #{open}\n    #{xattr}"))
' "$reversed_command_guide_stage/설치 안내 - Installation.txt"
create_stage_artifact \
    "$reversed_command_guide_stage" \
    "$reversed_command_guide_artifact"
expect_failure_containing "commands outside the approved fallback" \
    "$verify_dmg_script" \
    --dmg "$reversed_command_guide_artifact" \
    --checksum "$reversed_command_guide_artifact.sha256" \
    --version 0.1.0 \
    --build 1

echo "PASS release packaging scripts"
