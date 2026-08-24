#!/bin/bash

set -euo pipefail

test_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$test_directory/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-release-workflow.XXXXXX")"

cleanup() {
    local leaf_name

    leaf_name="$(basename "$test_root")"
    case "$leaf_name" in
        codex-gauge-release-workflow.*)
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

validate_fixture_repository() {
    (
        cd "$test_root/repository"
        "$validator" "$@"
    )
}

write_project_build() {
    local build="$1"

    mkdir -p "$test_root/repository/CodexGauge.xcodeproj"
    printf '%s\n' \
        "CURRENT_PROJECT_VERSION = $build;" \
        "CURRENT_PROJECT_VERSION = $build;" \
        > "$test_root/repository/CodexGauge.xcodeproj/project.pbxproj"
}

commit_project_build() {
    local build="$1"
    local message="$2"

    write_project_build "$build"
    git -C "$test_root/repository" add CodexGauge.xcodeproj/project.pbxproj
    git -C "$test_root/repository" commit -m "$message" >/dev/null
}

trap cleanup EXIT

validator="$repository_root/Scripts/validate-release-context.sh"
ci_workflow="$repository_root/.github/workflows/ci.yml"
workflow="$repository_root/.github/workflows/release.yml"
release_notes="$repository_root/.github/release-notes.md"

test -x "$validator" || fail "missing executable release context validator"
test -f "$ci_workflow" || fail "missing CI workflow"
test -f "$workflow" || fail "missing release workflow"
test -f "$release_notes" || fail "missing release notes template"

bash -n "$validator"
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$workflow"

if grep -E -q '^[[:space:]]+[A-Z][A-Z0-9_]*:[[:space:]]+\$\{\{[[:space:]]*runner\.temp' \
    "$ci_workflow" \
    "$workflow"; then
    fail "runner context is unavailable in workflow env declarations"
fi

if grep -q 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES' \
    "$ci_workflow" \
    "$workflow"; then
    fail "Xcode package tests cannot combine suppressed warnings with warnings as errors"
fi

grep -q '^  workflow_dispatch:' "$workflow" \
    || fail "manual artifact builds are not configured"
grep -q -- "- 'v\*'" "$workflow" \
    || fail "version tag builds are not configured"
grep -q '^permissions: {}' "$workflow" \
    || fail "workflow permissions are not denied by default"
grep -q 'contents: write' "$workflow" \
    || fail "draft publishing lacks explicit contents permission"
[ "$(grep -c 'contents: write' "$workflow")" = "1" ] \
    || fail "contents write permission is not isolated to draft publishing"
grep -q 'persist-credentials: false' "$workflow" \
    || fail "checkout credentials are persisted"
grep -q 'fetch-depth: 0' "$workflow" \
    || fail "release ancestry cannot be validated from a shallow checkout"
grep -q 'Scripts/build-release-dmg.sh' "$workflow" \
    || fail "release workflow does not use the verified packager"
grep -q 'Scripts/verify-release-dmg-layout.applescript' "$workflow" \
    || fail "release candidate lacks Finder layout verification"
grep -F -q 'find "$release_directory" -type f | wc -l' "$workflow" \
    || fail "release candidate file count is not verified"
grep -F -q '= "6"' "$workflow" \
    || fail "release candidate file count omits a verification file"
grep -F -q '"$release_directory/verification/verify-release-dmg-layout.applescript"' \
    "$workflow" \
    || fail "downloaded candidate does not require the Finder layout verifier"
grep -q 'Scripts/validate-release-context.sh' "$workflow" \
    || fail "release workflow does not validate tags and build numbers"
grep -q 'chmod +x' "$workflow" \
    || fail "downloaded verification scripts cannot execute"
grep -q 'swift test' "$workflow" \
    || fail "release workflow does not run the standard test suite"
grep -q 'swift run codex-gauge-tests' "$workflow" \
    || fail "release workflow does not run exhaustive tests"
grep -q 'gh release create' "$workflow" \
    || fail "release workflow does not create a GitHub draft"
grep -q -- '--draft' "$workflow" \
    || fail "release creation is not forced to draft"
grep -q "if: github.event_name == 'push'" "$workflow" \
    || fail "manual workflow runs can reach draft publishing"

if grep -E -q -- '--clobber|--draft=false|gh release (edit|delete|upload)' "$workflow"; then
    fail "release workflow can overwrite or automatically publish a release"
fi

if grep -E -q 'xattr|spctl|privileged[ _-]?helper' \
    "$ci_workflow" \
    "$workflow"; then
    fail "release automation can bypass macOS security policy"
fi

checkout_pin='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
upload_pin='actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
download_pin='actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
grep -q "$checkout_pin" "$workflow" || fail "checkout action is not pinned"
grep -q "$upload_pin" "$workflow" || fail "upload action is not pinned"
grep -q "$download_pin" "$workflow" || fail "download action is not pinned"

git init -b main "$test_root/repository" >/dev/null
git -C "$test_root/repository" config user.name "Release Fixture"
git -C "$test_root/repository" config user.email "fixture@example.invalid"

commit_project_build 1 "initial release"
git -C "$test_root/repository" tag v0.1.0
git -C "$test_root/repository" update-ref \
    refs/remotes/origin/main \
    "$(git -C "$test_root/repository" rev-parse HEAD)"

git -C "$test_root/repository" checkout --detach v0.1.0 >/dev/null 2>&1
(
    cd "$test_root/repository"
    "$validator" \
        --tag v0.1.0 \
        --version 0.1.0 \
        --build 1 \
        --main-ref refs/remotes/origin/main
)

git -C "$test_root/repository" checkout main >/dev/null 2>&1
commit_project_build 2 "second release"
git -C "$test_root/repository" tag v0.2.0
git -C "$test_root/repository" update-ref \
    refs/remotes/origin/main \
    "$(git -C "$test_root/repository" rev-parse HEAD)"
git -C "$test_root/repository" checkout --detach v0.2.0 >/dev/null 2>&1
(
    cd "$test_root/repository"
    "$validator" \
        --tag v0.2.0 \
        --version 0.2.0 \
        --build 2 \
        --main-ref refs/remotes/origin/main
)

git -C "$test_root/repository" checkout --detach v0.1.0 >/dev/null 2>&1
expect_failure validate_fixture_repository \
    --tag v0.1.0 \
    --version 0.1.0 \
    --build 1 \
    --main-ref refs/remotes/origin/main
git -C "$test_root/repository" checkout --detach v0.2.0 >/dev/null 2>&1

expect_failure validate_fixture_repository \
    --tag v0.2 \
    --version 0.2.0 \
    --build 2 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v00.2.0 \
    --version 00.2.0 \
    --build 2 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v0.2.0 \
    --version 0.2.1 \
    --build 2 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 1 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 2 \
    --main-ref refs/tags/v0.1.0

echo "PASS release workflow contracts"
