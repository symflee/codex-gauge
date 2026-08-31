#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: test-pr.sh [--developer-dir <path>] [--verbose] [--dry-run]" >&2
}

fail() {
    echo "pull-request test failed: $1" >&2
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

sanitize_stream() {
    ruby -e '
      replacements = ARGV.each_slice(2).reject { |source, _| source.empty? }
      STDIN.each_line do |line|
        replacements.each { |source, replacement| line = line.gsub(source, replacement) }
        STDOUT.write(line)
        STDOUT.flush
      end
    ' \
        "$repository_root" '<repository>' \
        "$developer_directory" '<developer-dir>' \
        "$temporary_directory" '<temporary>' \
        "$home_directory" '<home>'
}

capture_quiet_step() {
    local pipeline_statuses=()

    run_command "$@" 2>&1 | sanitize_stream >> "$log_path"
    pipeline_statuses=("${PIPESTATUS[@]}")
    [ "${pipeline_statuses[0]}" -eq 0 ] \
        || return "${pipeline_statuses[0]}"
    [ "${pipeline_statuses[1]}" -eq 0 ] \
        || return "${pipeline_statuses[1]}"
}

capture_verbose_step() {
    local pipeline_statuses=()

    run_command "$@" 2>&1 | sanitize_stream | tee -a "$log_path"
    pipeline_statuses=("${PIPESTATUS[@]}")
    [ "${pipeline_statuses[0]}" -eq 0 ] \
        || return "${pipeline_statuses[0]}"
    [ "${pipeline_statuses[1]}" -eq 0 ] \
        || return "${pipeline_statuses[1]}"
    [ "${pipeline_statuses[2]}" -eq 0 ] \
        || return "${pipeline_statuses[2]}"
}

emit_failure_tail() {
    tail -n 10 "$log_path" >&2
}

run_step() {
    local step_name="$1"
    local step_status=0

    shift
    if [ "$dry_run" -eq 1 ]; then
        run_command "$@"
        return
    fi
    printf 'STEP %s\n' "$step_name" >> "$log_path"
    set +e
    if [ "$verbose" -eq 1 ]; then
        capture_verbose_step "$@"
    else
        capture_quiet_step "$@"
    fi
    step_status="$?"
    set -e
    if [ "$step_status" -ne 0 ]; then
        echo "pull-request test failed: step=$step_name status=$step_status log=$log_name" >&2
        emit_failure_tail
        exit "$step_status"
    fi
    printf 'PASS %s\n' "$step_name" >> "$log_path"
}

prepare_log() {
    local log_directory=""

    if [ "$dry_run" -eq 1 ]; then
        return
    fi
    log_path="$repository_root/.build/test-pr.log"
    [ -z "$test_log_override" ] || log_path="$test_log_override"
    log_directory="$(dirname "$log_path")"
    if [ -e "$log_directory" ] || [ -L "$log_directory" ]; then
        [ -d "$log_directory" ] && [ ! -L "$log_directory" ] \
            || fail "test log directory must be a directory"
    fi
    mkdir -p "$log_directory"
    [ ! -L "$log_path" ] || fail "test log must not be a symbolic link"
    printf 'status=STARTED\n' > "$log_path"
}

resolve_developer_directory() {
    if [ -n "$developer_directory" ]; then
        return
    fi
    if [ -d /Applications/Xcode_26.6.app/Contents/Developer ]; then
        developer_directory=/Applications/Xcode_26.6.app/Contents/Developer
        return
    fi
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        developer_directory=/Applications/Xcode.app/Contents/Developer
    fi
}

verify_xcode_setup() {
    if [ "$dry_run" -eq 1 ]; then
        run_command /usr/bin/xcodebuild -checkFirstLaunchStatus
        return
    fi
    if ! run_command /usr/bin/xcodebuild -checkFirstLaunchStatus \
        >/dev/null 2>&1; then
        echo "pull-request test failed: open Xcode, accept the license, and finish first-launch setup" >&2
        exit 69
    fi
}

dry_run=0
verbose=0
developer_directory="${DEVELOPER_DIR:-}"
test_command_runner="${CODEX_GAUGE_TEST_COMMAND_RUNNER:-}"
test_log_override="${CODEX_GAUGE_TEST_LOG_PATH:-}"
log_name=".build/test-pr.log"
log_path=""
home_directory="${HOME:-__CODEX_GAUGE_HOME_UNAVAILABLE__}"
temporary_directory="${TMPDIR:-__CODEX_GAUGE_TEMPORARY_UNAVAILABLE__}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --developer-dir)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            developer_directory="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --verbose)
            verbose=1
            shift
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

resolve_developer_directory
[ -n "$developer_directory" ] \
    || fail "set DEVELOPER_DIR or pass --developer-dir"
[ -d "$developer_directory" ] || fail "DEVELOPER_DIR is not a directory"
export DEVELOPER_DIR="$developer_directory"
if [ -n "$test_command_runner" ]; then
    [ "${CODEX_GAUGE_TESTING:-}" = "1" ] \
        || fail "test command runner requires CODEX_GAUGE_TESTING=1"
    [ -x "$test_command_runner" ] || fail "test command runner is not executable"
fi
if [ -n "$test_log_override" ]; then
    [ "${CODEX_GAUGE_TESTING:-}" = "1" ] \
        || fail "test log override requires CODEX_GAUGE_TESTING=1"
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"

verify_xcode_setup
prepare_log
run_step whitespace git diff --check
run_step debug-build swift build \
    -c debug \
    --force-resolved-versions \
    --explicit-target-dependency-import-check error \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors
run_step exhaustive Scripts/run-exhaustive-tests.sh --skip-build

if [ "$dry_run" -eq 0 ]; then
    echo "PASS pull-request tests log=$log_name"
fi
