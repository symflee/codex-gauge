#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: test-fast.sh [--suite <core|protocol|process|refresh|settings|appkit|full>] [--filter <substring>] [--verbose] [--developer-dir <path>] [--dry-run]" >&2
}

fail() {
    echo "fast test failed: $1" >&2
    exit 1
}

print_command() {
    printf 'DRY-RUN'
    printf ' %q' "$@"
    printf '\n'
}

run_command() {
    if [ "$dry_run" -eq 1 ]; then
        print_command "$@"
        return
    fi
    if [ -n "$test_command_runner" ]; then
        "$test_command_runner" "$@"
        return
    fi
    "$@"
}

validate_suite() {
    case "$1" in
        core|protocol|process|refresh|settings|appkit|full)
            return
            ;;
    esac
    fail "unsupported suite: $1"
}

suite=""
filter=""
filter_set=0
verbose=0
dry_run=0
developer_directory="${DEVELOPER_DIR:-}"
test_command_runner="${CODEX_GAUGE_TEST_COMMAND_RUNNER:-}"
runner_arguments=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --suite)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            suite="$2"
            shift 2
            ;;
        --filter)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            filter="$2"
            filter_set=1
            shift 2
            ;;
        --verbose)
            verbose=1
            shift
            ;;
        --developer-dir)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            developer_directory="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

if [ -n "$suite" ]; then
    validate_suite "$suite"
    runner_arguments+=(--suite "$suite")
fi
[ "$filter_set" -eq 0 ] || [ -n "$filter" ] \
    || fail "filter must not be empty"
[ "$filter_set" -eq 0 ] || runner_arguments+=(--filter "$filter")
[ "$verbose" -eq 0 ] || runner_arguments+=(--verbose)
if [ -n "$developer_directory" ]; then
    [ -d "$developer_directory" ] \
        || fail "DEVELOPER_DIR is not a directory"
    export DEVELOPER_DIR="$developer_directory"
fi
if [ -n "$test_command_runner" ]; then
    [ "${CODEX_GAUGE_TESTING:-}" = "1" ] \
        || fail "test command runner requires CODEX_GAUGE_TESTING=1"
    [ -x "$test_command_runner" ] || fail "test command runner is not executable"
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

run_command git diff --check
if [ "${#runner_arguments[@]}" -eq 0 ]; then
    run_command Scripts/run-exhaustive-tests.sh
else
    run_command Scripts/run-exhaustive-tests.sh "${runner_arguments[@]}"
fi

if [ "$dry_run" -eq 0 ]; then
    echo "PASS fast tests"
fi
