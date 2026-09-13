#!/bin/bash

set -euo pipefail

test_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$test_directory/../.." && pwd)"
fixture_runner="$test_directory/Fixtures/command-recorder.sh"
fast_script="$repository_root/Scripts/test-fast.sh"
pull_request_script="$repository_root/Scripts/test-pr.sh"
release_script="$repository_root/Scripts/test-release-preflight.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-entry-point-tests.XXXXXX")"
command_log="$test_root/commands.log"
developer_directory="$test_root/Xcode[QA]&.app/Contents/Developer"
public_key_file="$test_root/SparklePublicEdKey.txt"
release_output="$test_root/release[QA]&output"

cleanup() {
    local leaf_name=""

    leaf_name="$(basename "$test_root")"
    case "$leaf_name" in
        codex-gauge-entry-point-tests.*)
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

assert_contains() {
    local path="$1"
    local expected="$2"

    grep -F -q -- "$expected" "$path" \
        || fail "missing expected text: $expected"
}

assert_not_contains() {
    local path="$1"
    local unexpected="$2"

    if grep -F -q -- "$unexpected" "$path"; then
        fail "found unexpected text: $unexpected"
    fi
}

assert_count() {
    local path="$1"
    local expected_count="$2"
    local pattern="$3"
    local actual_count=""

    actual_count="$(grep -F -c -- "$pattern" "$path" || true)"
    [ "$actual_count" -eq "$expected_count" ] \
        || fail "expected $expected_count occurrences of $pattern, found $actual_count"
}

run_with_recorder() {
    CODEX_GAUGE_TESTING=1 \
        CODEX_GAUGE_TEST_COMMAND_RUNNER="$fixture_runner" \
        CODEX_GAUGE_TEST_COMMAND_LOG="$command_log" \
        "$@"
}

trap cleanup EXIT

mkdir -p "$developer_directory" "$release_output"
release_output="$(cd "$release_output" && pwd)"
printf '%s\n' 'GX9rI+FshTLGq8g4+s1ep4m+DHaykgM0A5v6iz02jWE=' \
    > "$public_key_file"

test -x "$fixture_runner" || fail "missing executable command recorder"
test -x "$fast_script" || fail "missing executable fast test entry point"
test -x "$pull_request_script" || fail "missing executable pull-request test entry point"
test -x "$release_script" || fail "missing executable release preflight entry point"
bash -n "$fixture_runner"
bash -n "$fast_script"
bash -n "$pull_request_script"
bash -n "$release_script"

fast_dry_run_log="$test_root/fast-dry-run.log"
"$fast_script" --suite core --dry-run > "$fast_dry_run_log"
assert_contains "$fast_dry_run_log" 'DRY-RUN git diff --check'
assert_contains "$fast_dry_run_log" 'Scripts/run-exhaustive-tests.sh --suite core'

pull_request_dry_run_log="$test_root/pull-request-dry-run.log"
"$pull_request_script" \
    --developer-dir "$developer_directory" \
    --dry-run \
    > "$pull_request_dry_run_log"
assert_contains "$pull_request_dry_run_log" 'DRY-RUN swift build -c debug'
assert_not_contains "$pull_request_dry_run_log" 'DRY-RUN swift test'
assert_contains "$pull_request_dry_run_log" 'Scripts/run-exhaustive-tests.sh --skip-build'
assert_not_contains "$pull_request_dry_run_log" 'CodexGaugeUITests'

release_dry_run_output="$test_root/dry-release-output"
release_dry_run_log="$test_root/release-dry-run.log"
"$release_script" \
    --developer-dir "$developer_directory" \
    --version 0.2.0 \
    --build 3 \
    --public-key-file "$public_key_file" \
    --output-dir "$release_dry_run_output" \
    --dry-run \
    > "$release_dry_run_log"
assert_contains "$release_dry_run_log" 'Scripts/test-release-contracts.sh'
assert_contains "$release_dry_run_log" 'CodexGaugeUITests'
assert_contains "$release_dry_run_log" 'Scripts/build-release-dmg.sh'
assert_contains "$release_dry_run_log" 'OUTPUT_DIR'
assert_not_contains "$release_dry_run_log" "$release_dry_run_output"
assert_not_contains "$release_dry_run_log" 'GX9rI+FshTLGq8g4+s1ep4m+DHaykgM0A5v6iz02jWE='
test ! -e "$release_dry_run_output" \
    || fail "release dry-run created its output directory"

: > "$command_log"
run_with_recorder "$fast_script" \
    --suite process \
    --filter Decoder \
    --verbose \
    >/dev/null
assert_contains "$command_log" $'COMMAND\tgit\tdiff\t--check'
assert_contains "$command_log" $'run-exhaustive-tests.sh\t--suite\tprocess\t--filter\tDecoder\t--verbose'
assert_count "$command_log" 2 'COMMAND'
expect_failure "$fast_script" --suite unsupported
expect_failure "$fast_script" --filter ''

: > "$command_log"
expect_failure run_with_recorder "$fast_script"
expect_failure run_with_recorder "$fast_script" --verbose
expect_failure run_with_recorder "$fast_script" --dry-run
expect_failure run_with_recorder "$fast_script" \
    --developer-dir "$developer_directory"
test ! -s "$command_log" \
    || fail "missing fast test selection executed a command"

: > "$command_log"
run_with_recorder "$fast_script" --suite full >/dev/null
assert_contains "$command_log" $'COMMAND\tScripts/run-exhaustive-tests.sh\t--suite\tfull'
assert_not_contains "$command_log" $'\t--verbose'
assert_count "$command_log" 2 'COMMAND'

: > "$command_log"
run_with_recorder "$fast_script" --filter Decoder >/dev/null
assert_contains "$command_log" $'COMMAND\tScripts/run-exhaustive-tests.sh\t--filter\tDecoder'
assert_not_contains "$command_log" $'\t--suite\t'
assert_count "$command_log" 2 'COMMAND'

: > "$command_log"
pull_request_log="$test_root/test-pr.log"
pull_request_result="$(
    CODEX_GAUGE_TESTING=1 \
        CODEX_GAUGE_TEST_COMMAND_RUNNER="$fixture_runner" \
        CODEX_GAUGE_TEST_COMMAND_LOG="$command_log" \
        CODEX_GAUGE_TEST_LOG_PATH="$pull_request_log" \
        CODEX_GAUGE_TEST_COMMAND_OUTPUT="repository=$repository_root developer=$developer_directory temporary=${TMPDIR:-} home=${HOME:-}" \
        "$pull_request_script" --developer-dir "$developer_directory"
)"
[ "$(printf '%s\n' "$pull_request_result" | wc -l | tr -d '[:space:]')" -eq 1 ] \
    || fail "pull-request success output was not concise"
test -f "$pull_request_log" || fail "pull-request test did not create a log"
assert_contains "$pull_request_log" 'STEP debug-build'
assert_contains "$pull_request_log" 'STEP exhaustive'
assert_not_contains "$pull_request_log" 'STEP swift-testing'
assert_contains "$pull_request_log" 'repository=<repository>'
assert_contains "$pull_request_log" 'developer=<developer-dir>'
assert_contains "$pull_request_log" 'temporary=<temporary>'
assert_contains "$pull_request_log" 'home=<home>'
assert_not_contains "$pull_request_log" "$repository_root"
assert_not_contains "$pull_request_log" "$developer_directory"
[ -z "${HOME:-}" ] || assert_not_contains "$pull_request_log" "$HOME"

pull_request_verbose_log="$test_root/test-pr-verbose.log"
pull_request_verbose_result="$(
    CODEX_GAUGE_TESTING=1 \
        CODEX_GAUGE_TEST_COMMAND_RUNNER="$fixture_runner" \
        CODEX_GAUGE_TEST_COMMAND_LOG="$command_log" \
        CODEX_GAUGE_TEST_LOG_PATH="$pull_request_verbose_log" \
        CODEX_GAUGE_TEST_COMMAND_OUTPUT="repository=$repository_root developer=$developer_directory temporary=${TMPDIR:-} home=${HOME:-}" \
        "$pull_request_script" \
            --developer-dir "$developer_directory" \
            --verbose
)"
printf '%s\n' "$pull_request_verbose_result" | grep -F -q '<repository>' \
    || fail "pull-request verbose output omitted sanitized diagnostics"
if printf '%s\n' "$pull_request_verbose_result" | grep -F -q "$repository_root"; then
    fail "pull-request verbose output exposed the repository path"
fi
assert_contains "$command_log" $'COMMAND\t/usr/bin/xcodebuild\t-checkFirstLaunchStatus'
assert_contains "$command_log" $'COMMAND\tgit\tdiff\t--check'
assert_contains "$command_log" $'COMMAND\tswift\tbuild\t-c\tdebug'
assert_contains "$command_log" '--explicit-target-dependency-import-check'
assert_contains "$command_log" '-warnings-as-errors'
assert_contains "$command_log" '-strict-concurrency=complete'
assert_contains "$command_log" $'run-exhaustive-tests.sh\t--skip-build'
assert_not_contains "$command_log" $'\t-c\trelease'
assert_not_contains "$command_log" 'CodexGaugeUITests'
assert_not_contains "$command_log" 'build-release-dmg.sh'
assert_not_contains "$command_log" 'test_release_packaging.sh'
assert_not_contains "$command_log" $'\thdiutil\t'
assert_not_contains "$command_log" $'\tosascript\t'
assert_not_contains "$command_log" $'\topen\t'
assert_not_contains "$command_log" 'codex-gauge-dev'
assert_not_contains "$command_log" 'codex-gauge-smoke'

set +e
license_output="$(
    CODEX_GAUGE_TESTING=1 \
        CODEX_GAUGE_TEST_COMMAND_RUNNER="$fixture_runner" \
        CODEX_GAUGE_TEST_COMMAND_LOG="$command_log" \
        CODEX_GAUGE_TEST_FAIL_MATCH='-checkFirstLaunchStatus' \
        "$pull_request_script" --developer-dir "$developer_directory" 2>&1
)"
license_status="$?"
set -e
[ "$license_status" -ne 0 ] || fail "Xcode setup failure was accepted"
[ "$(printf '%s\n' "$license_output" | wc -l | tr -d '[:space:]')" -eq 1 ] \
    || fail "Xcode setup failure was not concise"
printf '%s\n' "$license_output" | grep -F -q 'accept the license' \
    || fail "Xcode setup failure did not explain the license action"

: > "$command_log"
expect_failure "$release_script" \
    --developer-dir "$developer_directory" \
    --version 0.2.0 \
    --build 3 \
    --public-key-file "$public_key_file" \
    --output-dir "$release_output"
release_result="$(
    CODEX_GAUGE_TESTING=1 \
        CODEX_GAUGE_TEST_COMMAND_RUNNER="$fixture_runner" \
        CODEX_GAUGE_TEST_COMMAND_LOG="$command_log" \
        CODEX_GAUGE_TEST_COMMAND_OUTPUT="repository=$repository_root developer=$developer_directory output=$release_output temporary=${TMPDIR:-} home=${HOME:-}" \
        CODEX_GAUGE_TEST_ECHO_ABSOLUTE_ARGUMENTS=1 \
        "$release_script" \
            --developer-dir "$developer_directory" \
            --version 0.2.0 \
            --build 3 \
            --public-key-file "$public_key_file" \
            --output-dir "$release_output" \
            --allow-local-release-effects
)"
[ "$(printf '%s\n' "$release_result" | wc -l | tr -d '[:space:]')" -eq 1 ] \
    || fail "release preflight success output was not concise"
assert_contains "$command_log" 'test-release-contracts.sh'
assert_contains "$command_log" 'CodexGaugeUITests'
assert_contains "$command_log" $'UI_TEST_EFFECTS\t1'
assert_contains "$command_log" 'build-release-dmg.sh'
assert_contains "$command_log" '--allow-local-release-effects'
assert_count "$command_log" 1 'build-release-dmg.sh'
assert_not_contains "$command_log" 'codex-gauge-smoke'
assert_not_contains "$command_log" 'private'
report_path="$release_output/release-preflight-report.txt"
release_log_path="$release_output/release-preflight.log"
test -f "$report_path" || fail "release preflight did not create a report"
test -f "$release_log_path" || fail "release preflight did not create a log"
assert_contains "$release_log_path" 'STEP release-contracts'
assert_contains "$release_log_path" 'STEP xcode-ui-smoke'
assert_contains "$release_log_path" 'STEP release-dmg'
assert_contains "$release_log_path" 'repository=<repository>'
assert_contains "$release_log_path" 'developer=<developer-dir>'
assert_contains "$release_log_path" 'output=<output-dir>'
assert_contains "$release_log_path" '<derived-data>'
assert_contains "$release_log_path" 'temporary=<temporary>'
assert_contains "$release_log_path" 'home=<home>'
assert_not_contains "$release_log_path" "$repository_root"
assert_not_contains "$release_log_path" "$developer_directory"
assert_not_contains "$release_log_path" "$release_output"
[ -z "${HOME:-}" ] || assert_not_contains "$release_log_path" "$HOME"
assert_contains "$report_path" 'status=PASS'
assert_contains "$report_path" 'version=0.2.0'
assert_contains "$report_path" 'build=3'
assert_contains "$report_path" 'checks=release-contracts,xcode-ui-smoke,release-dmg'
assert_contains "$report_path" 'sha='
assert_contains "$report_path" 'duration_seconds='
assert_contains "$report_path" 'log=release-preflight.log'
printf '%s\n' "$release_result" | grep -F -q 'RELEASE_PREFLIGHT PASS' \
    || fail "release preflight did not emit a concise result"
printf '%s\n' "$release_result" | grep -F -q 'report=release-preflight-report.txt' \
    || fail "release preflight result omitted the report path"

verbose_release_output="$test_root/verbose-release-output"
mkdir "$verbose_release_output"
verbose_release_output="$(cd "$verbose_release_output" && pwd)"
verbose_release_result="$(
    CODEX_GAUGE_TESTING=1 \
        CODEX_GAUGE_TEST_COMMAND_RUNNER="$fixture_runner" \
        CODEX_GAUGE_TEST_COMMAND_LOG="$command_log" \
        CODEX_GAUGE_TEST_COMMAND_OUTPUT="repository=$repository_root developer=$developer_directory output=$verbose_release_output temporary=${TMPDIR:-} home=${HOME:-}" \
        CODEX_GAUGE_TEST_ECHO_ABSOLUTE_ARGUMENTS=1 \
        "$release_script" \
            --developer-dir "$developer_directory" \
            --version 0.2.0 \
            --build 3 \
            --public-key-file "$public_key_file" \
            --output-dir "$verbose_release_output" \
            --allow-local-release-effects \
            --verbose
)"
printf '%s\n' "$verbose_release_result" | grep -F -q '<derived-data>' \
    || fail "release verbose output omitted sanitized DerivedData diagnostics"
if printf '%s\n' "$verbose_release_result" | grep -F -q "$repository_root"; then
    fail "release verbose output exposed the repository path"
fi
if printf '%s\n' "$verbose_release_result" | grep -F -q "$verbose_release_output"; then
    fail "release verbose output exposed the output path"
fi

failed_release_output="$test_root/failed-release-output"
mkdir "$failed_release_output"
failed_release_output="$(cd "$failed_release_output" && pwd)"
set +e
failed_release_result="$(
    CODEX_GAUGE_TESTING=1 \
        CODEX_GAUGE_TEST_COMMAND_RUNNER="$fixture_runner" \
        CODEX_GAUGE_TEST_COMMAND_LOG="$command_log" \
        CODEX_GAUGE_TEST_FAIL_MATCH='Scripts/test-release-contracts.sh' \
        CODEX_GAUGE_TEST_COMMAND_OUTPUT="repository=$repository_root developer=$developer_directory output=$failed_release_output temporary=${TMPDIR:-} home=${HOME:-}" \
        CODEX_GAUGE_TEST_ECHO_ABSOLUTE_ARGUMENTS=1 \
        "$release_script" \
            --developer-dir "$developer_directory" \
            --version 0.2.0 \
            --build 3 \
            --public-key-file "$public_key_file" \
            --output-dir "$failed_release_output" \
            --allow-local-release-effects \
            2>&1
)"
failed_release_status="$?"
set -e
[ "$failed_release_status" -ne 0 ] \
    || fail "release preflight accepted a failed release step"
printf '%s\n' "$failed_release_result" | grep -F -q \
    'step=release-contracts status=70 log=release-preflight.log' \
    || fail "release failure did not identify the failed step"
printf '%s\n' "$failed_release_result" | grep -F -q '<repository>' \
    || fail "release failure tail omitted sanitized diagnostics"
if printf '%s\n' "$failed_release_result" | grep -F -q "$repository_root"; then
    fail "release failure tail exposed the repository path"
fi
[ "$(printf '%s\n' "$failed_release_result" | wc -l | tr -d '[:space:]')" -le 15 ] \
    || fail "release failure output was not concise"
test -f "$failed_release_output/release-preflight.log" \
    || fail "failed release preflight did not preserve its log"

expect_failure "$release_script" \
    --developer-dir "$developer_directory" \
    --version v0.2.0 \
    --build 3 \
    --public-key-file "$public_key_file" \
    --output-dir "$test_root/invalid-version"
expect_failure "$release_script" \
    --developer-dir "$developer_directory" \
    --version 0.2.0 \
    --build 0 \
    --public-key-file "$public_key_file" \
    --output-dir "$test_root/invalid-build"
expect_failure "$release_script" \
    --developer-dir "$developer_directory" \
    --version 0.2.0 \
    --build 3 \
    --public-key-file "$test_root/missing-key" \
    --output-dir "$test_root/missing-key-output"

echo "PASS test entry point contract tests"
