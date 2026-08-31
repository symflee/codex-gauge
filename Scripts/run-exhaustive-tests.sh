#!/bin/bash

set -euo pipefail

fail() {
    echo "exhaustive test verification failed: $1" >&2
    exit 1
}

emit_quiet_output() {
    awk '
        /^FAIL / { print; found = 1; next }
        /^SUMMARY / { print; found = 1; next }
        /^codex-gauge-tests: / { print; found = 1 }
        END { if (found == 0) exit 1 }
    ' "$1"
}

emit_toolchain_mismatch() {
    grep -E -q \
        'module compiled with Swift [^ ]+ cannot be imported by the Swift [^ ]+ compiler' \
        "$1" || return 1
    printf '%s\n' \
        "codex-gauge-tests: toolchain and build cache mismatch; select matching Xcode or regenerate the build cache"
}

emit_failure_output() {
    if emit_quiet_output "$1"; then
        return
    fi
    if emit_toolchain_mismatch "$1"; then
        return
    fi
    cat "$1"
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

runner_command=(swift run --force-resolved-versions)
forwarded_arguments=()
show_verbose_output=false
lists_tests=false
expects_option_value=false
skip_build=false

for argument in "$@"; do
    if [ "$expects_option_value" = true ]; then
        forwarded_arguments+=("$argument")
        expects_option_value=false
        continue
    fi
    case "$argument" in
        --skip-build)
            skip_build=true
            ;;
        --verbose)
            show_verbose_output=true
            forwarded_arguments+=("$argument")
            ;;
        --list)
            lists_tests=true
            forwarded_arguments+=("$argument")
            ;;
        --suite|--filter)
            expects_option_value=true
            forwarded_arguments+=("$argument")
            ;;
        *)
            forwarded_arguments+=("$argument")
            ;;
    esac
done

if [ "$skip_build" = true ]; then
    runner_command+=(--skip-build)
fi
runner_command+=(codex-gauge-tests --verbose)
if [ "${#forwarded_arguments[@]}" -gt 0 ]; then
    runner_command+=("${forwarded_arguments[@]}")
fi

set +e
"${runner_command[@]}" >"$test_log" 2>&1
runner_status="$?"
set -e

if [ "$lists_tests" = true ]; then
    if [ "$runner_status" -eq 0 ]; then
        awk '/^TEST / { print }' "$test_log"
        exit 0
    fi
    emit_failure_output "$test_log"
    exit "$runner_status"
fi

if [ "$show_verbose_output" = true ]; then
    cat "$test_log"
fi

if [ "$runner_status" -ne 0 ]; then
    if [ "$show_verbose_output" = false ]; then
        emit_failure_output "$test_log"
    fi
    exit "$runner_status"
fi

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

if [ "$fail_count" -ne 0 ]; then
    if [ "$show_verbose_output" = false ]; then
        emit_quiet_output "$test_log"
    fi
    exit 1
fi

expected_summary="SUMMARY total=$run_count pass=$pass_count fail=$fail_count"
grep -F -x -q "$expected_summary" "$test_log" \
    || fail "runner summary does not match reported results"

if [ "$show_verbose_output" = false ]; then
    printf '%s\n' "$expected_summary"
fi

echo "PASS exhaustive test completion verification"
