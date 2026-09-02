#!/bin/bash

set -euo pipefail

test_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$test_directory/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-release-workflow.XXXXXX")"

cleanup() {
    local leaf_name

    leaf_name="$(basename "$test_root")"
    case "$leaf_name" in
        codex-gauge-release-workflow.*)
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

verify_test_key_pair() {
    local private_seed="$1"
    local expected_public_key="$2"
    local derived_public_key=""

    derived_public_key="$(printf '%s' "$private_seed" \
        | "$test_key_deriver")" || return 1
    [ "$derived_public_key" = "$expected_public_key" ]
}

verify_ci_test_tier() {
    local workflow_path="$1"

    ruby -e '
      require "yaml"
      document = YAML.load_file(ARGV.fetch(0))
      steps = document.fetch("jobs").fetch("build-test").fetch("steps")
      runs = steps.map { |step| step["run"] }.compact
      exit 1 unless runs.length == 3

      toolchain = runs.find { |run| run.include?("xcodebuild -version") }
      entrypoints = runs.find do |run|
        run.strip == "bash Tests/TestEntryPointTests/test_test_entry_points.sh"
      end
      pull_request = runs.find { |run| run.strip == "Scripts/test-pr.sh" }
      exit 1 unless [toolchain, entrypoints, pull_request].all?
      exit 1 if runs.any? { |run| run.start_with?("swift package describe") }
      exit 1 if runs.any? { |run| run.start_with?("swift build") }
      exit 1 if runs.any? { |run| run.start_with?("swift test") }
      exit 1 if runs.any? { |run| run.include?("swift run codex-gauge-tests") }
      exit 1 if runs.any? { |run| run.include?("swift build -c release") }
      exit 1 if runs.any? { |run| run.include?("Tests/Release") }
      exit 1 if runs.any? { |run| run.include?("xcodebuild test") }
      exit 1 if runs.any? { |run| run.include?("Scripts/build-release-dmg.sh") }
    ' "$workflow_path"
}

verify_release_test_tier() {
    local workflow_path="$1"

    ruby -e '
      require "yaml"
      document = YAML.load_file(ARGV.fetch(0))
      jobs = document.fetch("jobs")
      steps = jobs.fetch("build_package").fetch("steps")
      runs = steps.map { |step| step["run"] }.compact
      exit 1 unless runs.length == 4

      toolchain = runs.find { |run| run.include?("xcodebuild -version") }
      metadata = runs.find do |run|
        run.include?("Scripts/validate-release-context.sh")
      end
      contracts = runs.find { |run| run.strip == "Scripts/test-release-contracts.sh" }
      ui_smoke = runs.find do |run|
        run.include?("-only-testing:CodexGaugeUITests")
      end
      exit 1 unless [toolchain, metadata, contracts, ui_smoke].all?
      exit 1 unless ui_smoke.include?("-disableAutomaticPackageResolution")
      ui_step = steps.find { |step| step.fetch("run", "").include?("CodexGaugeUITests") }
      exit 1 unless ui_step.fetch("env", {})["CODEX_GAUGE_LOCAL_RELEASE_EFFECTS_ALLOWED"] == "1"
      exit 1 if runs.any? { |run| run.start_with?("swift package describe") }
      exit 1 if runs.any? { |run| run.start_with?("swift build -c debug") }
      exit 1 if runs.any? { |run| run.start_with?("swift test") }
      exit 1 if runs.any? { |run| run.include?("Scripts/run-exhaustive-tests.sh") }
      exit 1 if runs.any? { |run| run.include?("swift build -c release") }
      exit 1 if runs.any? { |run| run.include?("-only-testing:CodexGaugeUnitTests") }

      candidate_steps = jobs.fetch("build_candidate").fetch("steps")
      candidate_build = candidate_steps.find do |step|
        step.fetch("run", "").include?("Scripts/build-release-dmg.sh")
      end
      exit 1 unless candidate_build
      exit 1 unless candidate_build.fetch("run").include?("--allow-local-release-effects")
      exit 1 if candidate_build.fetch("run").include?("Scripts/verify-release-dmg.sh")
    ' "$workflow_path"
}

validate_fixture_repository() {
    (
        cd "$test_root/repository"
        "$validator" "$@"
    )
}

write_project_build() {
    local build="$1"

    mkdir -p "$test_root/repository/CodexGauge.xcodeproj"
    printf '%s\n' \
        "CURRENT_PROJECT_VERSION = $build;" \
        "CURRENT_PROJECT_VERSION = $build;" \
        > "$test_root/repository/CodexGauge.xcodeproj/project.pbxproj"
}

commit_project_build() {
    local build="$1"
    local message="$2"

    write_project_build "$build"
    git -C "$test_root/repository" add CodexGauge.xcodeproj/project.pbxproj
    git -C "$test_root/repository" commit -m "$message" >/dev/null
}

trap cleanup EXIT

validator="$repository_root/Scripts/validate-release-context.sh"
exhaustive_runner="$repository_root/Scripts/run-exhaustive-tests.sh"
ci_workflow="$repository_root/.github/workflows/ci.yml"
workflow="$repository_root/.github/workflows/release.yml"
release_contracts="$repository_root/Scripts/test-release-contracts.sh"
release_notes="$repository_root/.github/release-notes.md"
key_deriver_source="$repository_root/Scripts/derive-sparkle-public-key.swift"
signature_verifier_source="$repository_root/Scripts/verify-sparkle-signature.swift"

test -x "$validator" || fail "missing executable release context validator"
test -x "$exhaustive_runner" || fail "missing executable exhaustive test verifier"
test -f "$ci_workflow" || fail "missing CI workflow"
test -f "$workflow" || fail "missing release workflow"
test -f "$release_notes" || fail "missing release notes template"
test -f "$key_deriver_source" || fail "missing Sparkle public-key derivation source"
test -x "$release_contracts" || fail "missing executable release contracts entry point"
test -f "$signature_verifier_source" || fail "missing Sparkle signature verifier source"

case "$(uname -m)" in
    arm64|x86_64) swift_architecture="$(uname -m)" ;;
    *) fail "unsupported Swift test architecture" ;;
esac
test_key_deriver="$test_root/derive-sparkle-public-key"
xcrun swiftc \
    -target "$swift_architecture-apple-macosx13.0" \
    -module-cache-path "$test_root/swift-module-cache" \
    "$key_deriver_source" \
    -o "$test_key_deriver"
test_private_seed='KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio='
test_public_key='GX9rI+FshTLGq8g4+s1ep4m+DHaykgM0A5v6iz02jWE='
verify_test_key_pair "$test_private_seed" "$test_public_key" \
    || fail "valid test-only Sparkle keypair was rejected"
expect_failure verify_test_key_pair "$test_private_seed" \
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
expect_failure verify_test_key_pair 'not-a-32-byte-seed' "$test_public_key"

bash -n "$validator"
bash -n "$exhaustive_runner"
ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path) }' \
    "$ci_workflow" \
    "$workflow"
ruby -e '
  require "yaml"
  document = YAML.load_file(ARGV.fetch(0))
  jobs = document.fetch("jobs")
  signing = jobs.fetch("sign_appcast")
  exit(1) if signing.fetch("steps").any? do |step|
    step.fetch("uses", "").start_with?("actions/checkout@")
  end
  secret_steps = signing.fetch("steps").select do |step|
    step.fetch("env", {}).key?("SPARKLE_EDDSA_PRIVATE_KEY")
  end
  exit(1) unless secret_steps.length == 1
  exit(1) if signing.fetch("env", {}).key?("SPARKLE_EDDSA_PRIVATE_KEY")
  xcode_runs = jobs.values.flat_map do |job|
    job.fetch("steps", []).map { |step| step["run"] }.compact
  end.select do |run|
    run.include?("xcodebuild") && !run.include?("xcodebuild -version")
  end
  exit(1) if xcode_runs.empty?
  exit(1) unless xcode_runs.all? do |run|
    run.include?("-disableAutomaticPackageResolution")
  end
  derivation_run = signing.fetch("steps").map { |step| step["run"] }.compact.find do |run|
    run.include?("derive-sparkle-public-key.swift")
  end
  exit(1) unless derivation_run
  match = derivation_run.match(/<<\x27SWIFT\x27\n(.*?)\nSWIFT\n/m)
  exit(1) unless match
  inline_source = "#{match[1]}\n"
  exit(1) unless inline_source == File.binread(ARGV.fetch(1))
' "$workflow" "$key_deriver_source" \
    || fail "release signing secret isolation, key derivation, or package locking is incomplete"

if grep -E -q '^[[:space:]]+[A-Z][A-Z0-9_]*:[[:space:]]+\$\{\{[[:space:]]*runner\.temp' \
    "$ci_workflow" \
    "$workflow"; then
    fail "runner context is unavailable in workflow env declarations"
fi

if grep -q 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES' \
    "$ci_workflow" \
    "$workflow"; then
    fail "Xcode package tests cannot combine suppressed warnings with warnings as errors"
fi

grep -q '^  workflow_dispatch:' "$workflow" \
    || fail "manual artifact builds are not configured"
grep -q 'description: Existing vX.Y.Z tag to build' "$workflow" \
    || fail "manual artifact builds do not require an exact existing tag"
grep -q -- "- 'v\*'" "$workflow" \
    || fail "version tag builds are not configured"
grep -q '^permissions: {}' "$workflow" \
    || fail "workflow permissions are not denied by default"
grep -q 'contents: write' "$workflow" \
    || fail "draft publishing lacks explicit contents permission"
[ "$(grep -c 'contents: write' "$workflow")" = "1" ] \
    || fail "contents write permission is not isolated to draft publishing"
grep -q 'persist-credentials: false' "$workflow" \
    || fail "checkout credentials are persisted"
grep -q 'fetch-depth: 0' "$workflow" \
    || fail "release ancestry cannot be validated from a shallow checkout"
grep -q 'Scripts/build-release-dmg.sh' "$workflow" \
    || fail "release workflow does not use the verified packager"
grep -q 'Scripts/verify-release-dmg-layout.applescript' "$workflow" \
    || fail "release candidate lacks Finder layout verification"
grep -F -q 'find "$release_directory" -type f | wc -l' "$workflow" \
    || fail "release candidate file count is not verified"
grep -F -q '= "11"' "$workflow" \
    || fail "release candidate file count omits an updater verification file"
grep -F -q 'cp Scripts/verify-sparkle-signature.swift "$release_directory/verification/"' \
    "$workflow" \
    || fail "release candidate omits the public signature verifier source"
grep -F -q '"$release_directory/verification/verify-sparkle-signature.swift"' \
    "$workflow" \
    || fail "draft publishing does not compile the public signature verifier"
grep -F -q -- '--signature-verifier-tool "$signature_verifier"' "$workflow" \
    || fail "draft publishing does not cryptographically verify public signatures"
grep -F -q '"$release_directory/verification/verify-release-dmg-layout.applescript"' \
    "$workflow" \
    || fail "downloaded candidate does not require the Finder layout verifier"
grep -q 'Scripts/validate-release-context.sh' "$workflow" \
    || fail "release workflow does not validate tags and build numbers"
grep -F -q '"$tools_directory/generate_appcast"' "$workflow" \
    || fail "signing job does not use official generate_appcast"
grep -q 'Scripts/verify-release-appcast.sh' "$workflow" \
    || fail "release workflow does not verify the signed appcast"
grep -q 'Tests/ReleaseAppcastTests/test_release_appcast.sh' "$release_contracts" \
    || fail "release workflow omits appcast contract tests"
grep -q 'chmod +x' "$workflow" \
    || fail "downloaded verification scripts cannot execute"
verify_ci_test_tier "$ci_workflow" \
    || fail "CI test tier is not limited to fast functional checks"
verify_release_test_tier "$workflow" \
    || fail "release test tier duplicates general checks or omits release gates"
grep -q 'gh release create' "$workflow" \
    || fail "release workflow does not create a GitHub draft"
grep -q -- '--draft' "$workflow" \
    || fail "release creation is not forced to draft"
if grep -q 'Verify draft release' "$workflow"; then
    fail "release workflow contains redundant live validation"
fi
grep -q "if: github.event_name == 'push'" "$workflow" \
    || fail "manual workflow runs can reach draft publishing"
grep -F -q 'Distribution/SparklePublicEdKey.txt' "$workflow" \
    || fail "release build does not use the tracked public key"
grep -F -q 'SPARKLE_EDDSA_PRIVATE_KEY: ${{ secrets.SPARKLE_EDDSA_PRIVATE_KEY }}' "$workflow" \
    || fail "appcast signing does not use the repository private key secret"
[ "$(grep -F -c 'SPARKLE_EDDSA_PRIVATE_KEY: ${{ secrets.SPARKLE_EDDSA_PRIVATE_KEY }}' "$workflow")" = "1" ] \
    || fail "private key secret is exposed outside the signing step"
grep -F -q 'private_ed_key="$SPARKLE_EDDSA_PRIVATE_KEY"' "$workflow" \
    || fail "private key is not copied into a non-exported shell variable"
grep -F -q 'printf '\''%s'\'' "$private_ed_key"' "$workflow" \
    || fail "private key is not delivered over stdin"
grep -F -q 'unset SPARKLE_EDDSA_PRIVATE_KEY' "$workflow" \
    || fail "private key remains inherited by unrelated signing-step children"
grep -F -q 'import CryptoKit' "$workflow" \
    || fail "signing job does not use system CryptoKit"
grep -F -q 'Curve25519.Signing.PrivateKey(' "$workflow" \
    || fail "signing job does not construct an Ed25519 private key"
grep -F -q 'rawRepresentation: seed' "$workflow" \
    || fail "signing job does not derive the Ed25519 public key"
grep -F -q 'seed.count == 32' "$workflow" \
    || fail "signing job accepts unsupported Sparkle private-key formats"
grep -F -q 'test "$derived_public_key" = "$candidate_public_key"' "$workflow" \
    || fail "signing job does not bind the private seed to the candidate public key"
if grep -E -q -- '--ed-key-file[ =]+\$\{?\{?[[:space:]]*(secrets\.|SPARKLE_EDDSA_PRIVATE_KEY)' \
    "$workflow"; then
    fail "private key can be exposed through command arguments"
fi
grep -F -q 'https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip' \
    "$workflow" \
    || fail "Sparkle release tools are not pinned to 2.9.6"
grep -F -q '8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606' \
    "$workflow" \
    || fail "Sparkle release tools lack the pinned archive digest"

if grep -E -q -- '--clobber|--draft=false|gh release (edit|delete|upload)' "$workflow"; then
    fail "release workflow can overwrite or automatically publish a release"
fi

if grep -E -q 'xattr|spctl|privileged[ _-]?helper' \
    "$ci_workflow" \
    "$workflow"; then
    fail "release automation can bypass macOS security policy"
fi

checkout_pin='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
upload_pin='actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
download_pin='actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
grep -q "$checkout_pin" "$workflow" || fail "checkout action is not pinned"
grep -q "$upload_pin" "$workflow" || fail "upload action is not pinned"
grep -q "$download_pin" "$workflow" || fail "download action is not pinned"

grep -F -q '"$release_directory/appcast.xml#Signed Sparkle update feed"' \
    "$workflow" \
    || fail "draft release does not attach appcast.xml"
ruby -e '
  require "yaml"
  document = YAML.load_file(ARGV.fetch(0))
  steps = document.fetch("jobs").fetch("publish_draft").fetch("steps")
  creation = steps.find do |step|
    step.fetch("run", "").include?("gh release create")
  end
  exit 1 unless creation
  assets = creation.fetch("run").scan(
    /"\$release_directory\/([^"#]+)#[^"]+"/
  ).flatten.sort
  exit 1 unless assets == [
    "CodexGauge.dmg",
    "CodexGauge.dmg.sha256",
    "appcast.xml"
  ]
' "$workflow" \
    || fail "draft release assets are not exactly the updater contract"

git init -b main "$test_root/repository" >/dev/null
git -C "$test_root/repository" config user.name "Release Fixture"
git -C "$test_root/repository" config user.email "fixture@example.invalid"

commit_project_build 1 "initial release"
git -C "$test_root/repository" tag v0.1.0
git -C "$test_root/repository" update-ref \
    refs/remotes/origin/main \
    "$(git -C "$test_root/repository" rev-parse HEAD)"

git -C "$test_root/repository" checkout --detach v0.1.0 >/dev/null 2>&1
(
    cd "$test_root/repository"
    "$validator" \
        --tag v0.1.0 \
        --version 0.1.0 \
        --build 1 \
        --main-ref refs/remotes/origin/main
)

git -C "$test_root/repository" checkout main >/dev/null 2>&1
commit_project_build 2 "second release"
git -C "$test_root/repository" tag v0.2.0
git -C "$test_root/repository" update-ref \
    refs/remotes/origin/main \
    "$(git -C "$test_root/repository" rev-parse HEAD)"
git -C "$test_root/repository" checkout --detach v0.2.0 >/dev/null 2>&1
(
    cd "$test_root/repository"
    "$validator" \
        --tag v0.2.0 \
        --version 0.2.0 \
        --build 2 \
        --main-ref refs/remotes/origin/main
)

git -C "$test_root/repository" checkout --detach v0.1.0 >/dev/null 2>&1
expect_failure validate_fixture_repository \
    --tag v0.1.0 \
    --version 0.1.0 \
    --build 1 \
    --main-ref refs/remotes/origin/main
git -C "$test_root/repository" checkout --detach v0.2.0 >/dev/null 2>&1

expect_failure validate_fixture_repository \
    --tag v0.2 \
    --version 0.2.0 \
    --build 2 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v00.2.0 \
    --version 00.2.0 \
    --build 2 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v0.2.0 \
    --version 0.2.1 \
    --build 2 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 1 \
    --main-ref refs/remotes/origin/main
expect_failure validate_fixture_repository \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 2 \
    --main-ref refs/tags/v0.1.0

git -C "$test_root/repository" checkout main >/dev/null 2>&1
printf '%s\n' 'unreleased' > "$test_root/repository/unreleased.txt"
git -C "$test_root/repository" add unreleased.txt
git -C "$test_root/repository" commit -m "unreleased main change" >/dev/null
git -C "$test_root/repository" update-ref \
    refs/remotes/origin/main \
    "$(git -C "$test_root/repository" rev-parse HEAD)"
git -C "$test_root/repository" checkout --detach v0.2.0 >/dev/null 2>&1
expect_failure validate_fixture_repository \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 2 \
    --main-ref refs/remotes/origin/main

echo "PASS release workflow contracts"
