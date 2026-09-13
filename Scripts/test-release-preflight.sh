#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: test-release-preflight.sh --version <X.Y.Z> --build <number> --public-key-file <path> --output-dir <path> [--developer-dir <path>] [--allow-local-release-effects] [--verbose] [--dry-run]" >&2
}

fail() {
    echo "release preflight failed: $1" >&2
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
        "$derived_data_root" '<derived-data>' \
        "$output_directory" '<output-dir>' \
        "$developer_directory" '<developer-dir>' \
        "$repository_root" '<repository>' \
        "$temporary_directory" '<temporary>' \
        "$home_directory" '<home>'
}

run_release_build() {
    if [ "$dry_run" -eq 1 ]; then
        print_command Scripts/build-release-dmg.sh \
            --output-directory OUTPUT_DIR \
            --version "$version" \
            --build "$build" \
            --sparkle-public-ed-key PUBLIC_KEY \
            --allow-local-release-effects
        return
    fi
    run_step release-dmg Scripts/build-release-dmg.sh \
        --output-directory "$output_directory" \
        --version "$version" \
        --build "$build" \
        --sparkle-public-ed-key "$public_key" \
        --allow-local-release-effects
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

capture_quiet_step() {
    local pipeline_statuses=()

    run_command "$@" 2>&1 | sanitize_stream >> "$log_path"
    pipeline_statuses=("${PIPESTATUS[@]}")
    [ "${pipeline_statuses[0]}" -eq 0 ] \
        || return "${pipeline_statuses[0]}"
    [ "${pipeline_statuses[1]}" -eq 0 ] \
        || return "${pipeline_statuses[1]}"
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
        echo "release preflight failed: step=$step_name status=$step_status log=$log_name" >&2
        emit_failure_tail
        exit "$step_status"
    fi
    printf 'PASS %s\n' "$step_name" >> "$log_path"
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
        echo "release preflight failed: open Xcode, accept the license, and finish first-launch setup" >&2
        exit 69
    fi
}

validate_public_key_file() {
    [ -f "$public_key_file" ] && [ ! -L "$public_key_file" ] \
        || fail "public key file must be a regular file"
    ruby -rbase64 -e '
      encoded = File.binread(ARGV.fetch(0)).delete_suffix("\n").delete_suffix("\r")
      decoded = Base64.strict_decode64(encoded)
      valid = decoded.bytesize == 32 && Base64.strict_encode64(decoded) == encoded
      exit(valid ? 0 : 1)
    ' "$public_key_file" >/dev/null 2>&1 \
        || fail "public key file must contain one canonical 32-byte base64 key"
}

prepare_output_directory() {
    if [ -e "$output_directory" ] || [ -L "$output_directory" ]; then
        [ -d "$output_directory" ] && [ ! -L "$output_directory" ] \
            || fail "output directory must be a directory"
    fi
    if [ "$dry_run" -eq 0 ]; then
        mkdir -p "$output_directory"
        output_directory="$(cd "$output_directory" && pwd)"
    fi
}

cleanup() {
    local leaf_name=""

    if [ -n "$derived_data_root" ]; then
        leaf_name="$(basename "$derived_data_root")"
        case "$leaf_name" in
            codex-gauge-release-preflight.*)
                if [ -d "$derived_data_root" ] && [ ! -L "$derived_data_root" ]; then
                    rm -rf -- "$derived_data_root"
                fi
                ;;
        esac
    fi
    [ -z "$report_temporary_path" ] || rm -f -- "$report_temporary_path"
}

write_report() {
    report_temporary_path="$output_directory/.release-preflight-report.$$.tmp"
    {
        printf 'status=PASS\n'
        printf 'sha=%s\n' "$commit_sha"
        printf 'version=%s\n' "$version"
        printf 'build=%s\n' "$build"
        printf 'checks=%s\n' "$checks"
        printf 'duration_seconds=%s\n' "$duration_seconds"
        printf 'report=%s\n' "$report_name"
        printf 'log=%s\n' "$log_name"
    } > "$report_temporary_path"
    mv -n "$report_temporary_path" "$report_path"
    report_temporary_path=""
}

version=""
build=""
public_key_file=""
output_directory=""
developer_directory="${DEVELOPER_DIR:-}"
dry_run=0
verbose=0
allows_local_release_effects=0
test_command_runner="${CODEX_GAUGE_TEST_COMMAND_RUNNER:-}"
derived_data_root=""
report_temporary_path=""
log_path=""
home_directory="${HOME:-__CODEX_GAUGE_HOME_UNAVAILABLE__}"
temporary_directory="${TMPDIR:-__CODEX_GAUGE_TEMPORARY_UNAVAILABLE__}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            version="$2"
            shift 2
            ;;
        --build)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            build="$2"
            shift 2
            ;;
        --public-key-file)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            public_key_file="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            output_directory="$2"
            shift 2
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
        --allow-local-release-effects)
            allows_local_release_effects=1
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

printf '%s\n' "$version" | grep -E -q '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "version must use X.Y.Z"
printf '%s\n' "$build" | grep -E -q '^[1-9][0-9]*$' \
    || fail "build must be a positive integer"
[ -n "$public_key_file" ] || { usage; exit 64; }
[ -n "$output_directory" ] || { usage; exit 64; }
validate_public_key_file
if [ "$dry_run" -eq 0 ] && [ "$allows_local_release_effects" -ne 1 ]; then
    fail "pass --allow-local-release-effects to run XCUITest and DMG operations"
fi
if [ "$allows_local_release_effects" -eq 1 ]; then
    export CODEX_GAUGE_LOCAL_RELEASE_EFFECTS_ALLOWED=1
    # xcodebuild forwards TEST_RUNNER_ variables to the XCTest runner.
    export TEST_RUNNER_CODEX_GAUGE_LOCAL_RELEASE_EFFECTS_ALLOWED=1
fi
prepare_output_directory
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

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
cd "$repository_root"
commit_sha="$(git rev-parse --verify HEAD 2>/dev/null)" \
    || fail "repository HEAD is unavailable"
public_key="$(tr -d '\r\n' < "$public_key_file")"
checks="release-contracts,xcode-ui-smoke,release-dmg"
report_name="release-preflight-report.txt"
report_path="$output_directory/$report_name"
log_name="release-preflight.log"
log_path="$output_directory/$log_name"
if [ "$dry_run" -eq 0 ]; then
    [ ! -e "$report_path" ] && [ ! -L "$report_path" ] \
        || fail "release preflight report already exists"
    [ ! -e "$log_path" ] && [ ! -L "$log_path" ] \
        || fail "release preflight log already exists"
    derived_data_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-release-preflight.XXXXXX")"
else
    derived_data_root="<temporary-derived-data>"
fi
trap cleanup EXIT
start_seconds="$SECONDS"

verify_xcode_setup
if [ "$dry_run" -eq 0 ]; then
    {
        printf 'status=STARTED\n'
        printf 'sha=%s\n' "$commit_sha"
        printf 'version=%s\n' "$version"
        printf 'build=%s\n' "$build"
    } > "$log_path"
fi
run_step release-contracts Scripts/test-release-contracts.sh
run_step xcode-ui-smoke /usr/bin/xcodebuild test \
    -project CodexGauge.xcodeproj \
    -scheme CodexGauge \
    -destination platform=macOS \
    -derivedDataPath "$derived_data_root" \
    -disableAutomaticPackageResolution \
    -only-testing:CodexGaugeUITests \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=
run_release_build

if [ "$dry_run" -eq 1 ]; then
    echo "DRY-RUN release preflight checks=$checks"
    exit 0
fi

duration_seconds=$((SECONDS - start_seconds))
write_report
echo "RELEASE_PREFLIGHT PASS sha=$commit_sha version=$version build=$build checks=$checks duration_seconds=$duration_seconds report=$report_name log=$log_name"
