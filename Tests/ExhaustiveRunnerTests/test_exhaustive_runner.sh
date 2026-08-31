#!/bin/bash

set -euo pipefail

test_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$test_directory/../.." && pwd)"
runner="$repository_root/Scripts/run-exhaustive-tests.sh"
fixture_directory="$test_directory/Fixtures"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

run_fixture() {
    local test_case="$1"
    shift

    PATH="$fixture_directory:$PATH" \
        CODEX_GAUGE_FAKE_TEST_CASE="$test_case" \
        "$runner" "$@"
}

expect_line() {
    local output="$1"
    local expected="$2"

    printf '%s\n' "$output" | grep -F -x -q "$expected" \
        || fail "missing output: $expected"
}

expect_no_progress() {
    local output="$1"

    if printf '%s\n' "$output" | grep -E -q '^(RUN|PASS fixture$)'; then
        fail "quiet output included per-test progress"
    fi
}

expect_failure() {
    local test_case="$1"

    if run_fixture "$test_case" >/dev/null 2>&1; then
        fail "exhaustive verifier accepted $test_case"
    fi
}

test -x "$runner" || fail "missing executable exhaustive test verifier"
test -x "$fixture_directory/swift" || fail "missing executable Swift fixture"
bash -n "$runner"
bash -n "$fixture_directory/swift"

quiet_output="$(run_fixture success)"
expect_line "$quiet_output" "SUMMARY total=1 pass=1 fail=0"
expect_line "$quiet_output" "PASS exhaustive test completion verification"
expect_no_progress "$quiet_output"

skip_build_output="$(run_fixture skip-build --skip-build)"
expect_line "$skip_build_output" "SUMMARY total=1 pass=1 fail=0"

verbose_output="$(run_fixture success --verbose)"
expect_line "$verbose_output" "RUN fixture"
expect_line "$verbose_output" "PASS fixture"
expect_line "$verbose_output" "SUMMARY total=1 pass=1 fail=0"

list_output="$(run_fixture list --list)"
[ "$list_output" = "TEST fixture" ] || fail "list output was changed"

run_fixture forwarded \
    --suite protocol \
    --filter "MiXeD fixture name" >/dev/null

set +e
invalid_output="$(run_fixture invalid-selection --suite invalid 2>&1)"
invalid_status="$?"
set -e
[ "$invalid_status" -eq 64 ] || fail "invalid selection did not preserve status 64"
[ "$invalid_output" = "codex-gauge-tests: invalid selection" ] \
    || fail "invalid selection output was not one sanitized line"

set +e
failure_output="$(run_fixture reported-failure 2>&1)"
failure_status="$?"
set -e
[ "$failure_status" -eq 1 ] || fail "reported test failure did not fail"
expect_line "$failure_output" "FAIL fixture: expected failure"
expect_line "$failure_output" "SUMMARY total=1 pass=0 fail=1"
expect_no_progress "$failure_output"

set +e
toolchain_output="$(run_fixture toolchain-mismatch 2>&1)"
toolchain_status="$?"
set -e
[ "$toolchain_status" -eq 1 ] || fail "toolchain mismatch did not fail"
[ "$toolchain_output" = "codex-gauge-tests: toolchain and build cache mismatch; select matching Xcode or regenerate the build cache" ] \
    || fail "toolchain mismatch was not reduced to one sanitized line"

set +e
unknown_build_output="$(run_fixture unknown-build-error 2>&1)"
unknown_build_status="$?"
set -e
[ "$unknown_build_status" -eq 1 ] || fail "unknown build error did not fail"
expect_line "$unknown_build_output" "error: synthetic unknown compiler failure"

expect_failure missing-summary
expect_failure missing-result
expect_failure mismatched-result
expect_failure duplicate-summary
expect_failure mismatched-summary
expect_failure duplicate-result
expect_failure zero-tests
expect_failure nonzero-exit

echo "PASS exhaustive runner contract tests"
