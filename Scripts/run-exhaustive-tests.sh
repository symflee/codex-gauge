#!/bin/bash

set -euo pipefail

fail() {
    echo "exhaustive test verification failed: $1" >&2
    exit 1
}

verify_result_sequence() {
    awk '
        /^RUN / {
            if (pending != "") exit 1
            pending = substr($0, 5)
            next
        }
        /^PASS / {
            if (pending == "" || substr($0, 6) != pending) exit 1
            pending = ""
            next
        }
        /^FAIL / {
            prefix = "FAIL " pending ": "
            if (pending == "" || index($0, prefix) != 1) exit 1
            pending = ""
            next
        }
        END { if (pending != "") exit 1 }
    ' "$1"
}

test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-exhaustive-tests.XXXXXX")"
test_log="$test_root/output.log"

cleanup() {
    local leaf_name=""

    leaf_name="$(basename "$test_root")"
    case "$leaf_name" in
        codex-gauge-exhaustive-tests.*)
            if [ -d "$test_root" ] && [ ! -L "$test_root" ]; then
                rm -rf -- "$test_root"
            fi
            ;;
    esac
}

trap cleanup EXIT

set +e
swift run codex-gauge-tests 2>&1 | tee "$test_log"
pipeline_statuses=("${PIPESTATUS[@]}")
set -e

runner_status="${pipeline_statuses[0]}"
tee_status="${pipeline_statuses[1]}"
[ "$runner_status" -eq 0 ] || fail "runner exited with status $runner_status"
[ "$tee_status" -eq 0 ] || fail "test output capture exited with status $tee_status"
verify_result_sequence "$test_log" \
    || fail "runner reported a mismatched test result"

run_count="$(awk '/^RUN / { count += 1 } END { print count + 0 }' "$test_log")"
pass_count="$(awk '/^PASS / { count += 1 } END { print count + 0 }' "$test_log")"
fail_count="$(awk '/^FAIL / { count += 1 } END { print count + 0 }' "$test_log")"
summary_count="$(awk '/^SUMMARY / { count += 1 } END { print count + 0 }' "$test_log")"

[ "$run_count" -gt 0 ] || fail "runner did not start any tests"
[ "$summary_count" -eq 1 ] || fail "runner did not emit exactly one summary"
[ "$run_count" -eq $((pass_count + fail_count)) ] \
    || fail "runner stopped before reporting every result"
[ "$fail_count" -eq 0 ] || fail "runner reported $fail_count failures"

expected_summary="SUMMARY total=$run_count pass=$pass_count fail=$fail_count"
grep -F -x -q "$expected_summary" "$test_log" \
    || fail "runner summary does not match reported results"

echo "PASS exhaustive test completion verification"
