#!/bin/bash

set -euo pipefail

log_path="${CODEX_GAUGE_TEST_COMMAND_LOG:?}"
failure_match="${CODEX_GAUGE_TEST_FAIL_MATCH:-}"
fixture_output="${CODEX_GAUGE_TEST_COMMAND_OUTPUT:-}"
echo_absolute_arguments="${CODEX_GAUGE_TEST_ECHO_ABSOLUTE_ARGUMENTS:-0}"

printf 'COMMAND' >> "$log_path"
for argument in "$@"; do
    printf '\t%s' "$argument" >> "$log_path"
done
printf '\n' >> "$log_path"

if [ "${1:-}" = "/usr/bin/xcodebuild" ] && [ "${2:-}" = "test" ]; then
    printf 'UI_TEST_EFFECTS\t%s\n' \
        "${TEST_RUNNER_CODEX_GAUGE_LOCAL_RELEASE_EFFECTS_ALLOWED:-}" \
        >> "$log_path"
fi

if [ -n "$fixture_output" ]; then
    printf '%s\n' "$fixture_output"
fi
if [ "$echo_absolute_arguments" = "1" ]; then
    for argument in "$@"; do
        case "$argument" in
            /*)
                printf 'absolute argument=%s\n' "$argument"
                ;;
        esac
    done
fi

if [ -n "$failure_match" ]; then
    for argument in "$@"; do
        if [ "$argument" = "$failure_match" ]; then
            exit 70
        fi
    done
fi

exit 0
