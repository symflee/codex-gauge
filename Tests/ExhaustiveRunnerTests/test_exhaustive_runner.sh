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

    PATH="$fixture_directory:$PATH" \
        CODEX_GAUGE_FAKE_TEST_CASE="$test_case" \
        "$runner"
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

run_fixture success >/dev/null

expect_failure missing-summary
expect_failure missing-result
expect_failure mismatched-result
expect_failure duplicate-summary
expect_failure mismatched-summary
expect_failure reported-failure
expect_failure duplicate-result
expect_failure zero-tests
expect_failure nonzero-exit

echo "PASS exhaustive runner contract tests"
