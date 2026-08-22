#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: validate-release-context.sh --tag <vX.Y.Z> --version <X.Y.Z> --build <number> --main-ref <ref>" >&2
}

fail() {
    echo "release context validation failed: $1" >&2
    exit 1
}

tag=""
expected_version=""
expected_build=""
main_ref=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            tag="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            expected_version="$2"
            shift 2
            ;;
        --build)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            expected_build="$2"
            shift 2
            ;;
        --main-ref)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            main_ref="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[ -n "$tag" ] || { usage; exit 64; }
[ -n "$expected_version" ] || { usage; exit 64; }
[ -n "$expected_build" ] || { usage; exit 64; }
[ -n "$main_ref" ] || { usage; exit 64; }

semantic_version_pattern='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
grep -E -q "^v${semantic_version_pattern}$" <<< "$tag" \
    || fail "tag must use vX.Y.Z"
grep -E -q "^${semantic_version_pattern}$" <<< "$expected_version" \
    || fail "application version must use X.Y.Z"
grep -E -q '^[1-9][0-9]*$' <<< "$expected_build" \
    || fail "build must be a positive integer"
case "$main_ref" in
    refs/*) ;;
    *) fail "main ref must be fully qualified" ;;
esac
[ "${tag#v}" = "$expected_version" ] \
    || fail "tag and application version do not match"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "current directory is not a Git worktree"
git show-ref --verify --quiet "refs/tags/$tag" \
    || fail "release tag does not exist"
git rev-parse --verify --quiet "$main_ref^{commit}" >/dev/null \
    || fail "main ref does not exist"

tag_commit="$(git rev-parse "refs/tags/$tag^{commit}")"
head_commit="$(git rev-parse HEAD)"
[ "$tag_commit" = "$head_commit" ] \
    || fail "checked out commit does not match the release tag"
git merge-base --is-ancestor "$tag_commit" "$main_ref" \
    || fail "release tag is not contained in main"

release_tags=()
while IFS= read -r candidate; do
    if grep -E -q "^v${semantic_version_pattern}$" <<< "$candidate"; then
        release_tags[${#release_tags[@]}]="$candidate"
    fi
done < <(git tag --merged "$main_ref" --sort=-version:refname)

[ "${#release_tags[@]}" -gt 0 ] \
    || fail "release tag is missing from the reachable tag set"
[ "${release_tags[0]}" = "$tag" ] \
    || fail "release version does not increase from reachable tags"

previous_tag=""
if [ "${#release_tags[@]}" -gt 1 ]; then
    previous_tag="${release_tags[1]}"
fi

if [ -n "$previous_tag" ]; then
    previous_project="$(git show \
        "$previous_tag:CodexGauge.xcodeproj/project.pbxproj")" \
        || fail "previous release project metadata is missing"
    previous_build="$(awk '
        $1 == "CURRENT_PROJECT_VERSION" {
            value = $3
            sub(/;$/, "", value)
            values[value] = 1
        }
        END {
            for (value in values) {
                count += 1
                result = value
            }
            if (count == 1) {
                print result
            }
        }
    ' <<< "$previous_project")"
    grep -E -q '^[1-9][0-9]*$' <<< "$previous_build" \
        || fail "previous release build is ambiguous"
    [ "$expected_build" -gt "$previous_build" ] \
        || fail "build must increase from the previous release"
fi

echo "PASS release context validation"
