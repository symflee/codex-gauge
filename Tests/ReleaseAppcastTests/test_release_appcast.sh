#!/bin/bash

set -euo pipefail

test_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$test_directory/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-appcast-tests.XXXXXX")"

cleanup() {
    local leaf_name

    leaf_name="$(basename "$test_root")"
    case "$leaf_name" in
        codex-gauge-appcast-tests.*)
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

copy_and_replace() {
    local source_path="$1"
    local destination_path="$2"
    local old_value="$3"
    local new_value="$4"

    ruby -e '
      source, destination, old_value, new_value = ARGV
      text = File.binread(source)
      abort("fixture value missing") unless text.include?(old_value)
      text = text.sub(old_value, new_value)
      marker = "<!-- sparkle-signatures:"
      if text.include?(marker)
        length = text.index(marker)
        text = text.sub(/length: [0-9]+\n-->\s*\z/, "length: #{length}\n-->\n")
      end
      File.binwrite(destination, text)
    ' "$source_path" "$destination_path" "$old_value" "$new_value"
}

trap cleanup EXIT

generate_script="$repository_root/Scripts/generate-release-appcast.sh"
verify_script="$repository_root/Scripts/verify-release-appcast.sh"
signature_verifier_source="$repository_root/Scripts/verify-sparkle-signature.swift"
archive_path="$test_root/CodexGauge.dmg"
appcast_path="$test_root/appcast.xml"
public_key_path="$test_root/public-key.txt"
fake_tool="$test_root/generate_appcast"
fake_verify_tool="$test_root/sign_update"

test -x "$generate_script" || fail "missing appcast generator"
test -x "$verify_script" || fail "missing appcast verifier"
test -f "$signature_verifier_source" || fail "missing public signature verifier"
bash -n "$generate_script"
bash -n "$verify_script"

case "$(uname -m)" in
    arm64|x86_64) swift_architecture="$(uname -m)" ;;
    *) fail "unsupported Swift test architecture" ;;
esac
signature_verifier="$test_root/verify-sparkle-signature"
xcrun swiftc \
    -target "$swift_architecture-apple-macosx13.0" \
    -module-cache-path "$test_root/swift-module-cache" \
    "$signature_verifier_source" \
    -o "$signature_verifier"
test -x "$signature_verifier" || fail "public signature verifier did not compile"

printf '%s\n' 'synthetic full update archive' > "$archive_path"
archive_length="$(wc -c < "$archive_path" | tr -d '[:space:]')"
archive_signature='3EiKEuzlU1xght2K4czv/+JHjNkX1Zx2OOqHdxSYkMYqR9ARih/CPGAHlFkzFyiyw7RWdg+uk+Zek2dvCQmIBw=='
appcast_prefix="$test_root/appcast-prefix.xml"
cat > "$appcast_prefix" <<EOF
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications require re-signing.
-->
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Codex Gauge Changelog</title>
    <item>
      <title>Version 0.2.0</title>
      <sparkle:version>3</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/symflee/codex-gauge/releases/download/v0.2.0/CodexGauge.dmg" length="$archive_length" type="application/octet-stream" sparkle:edSignature="$archive_signature"/>
    </item>
  </channel>
</rss>
EOF
feed_length="$(wc -c < "$appcast_prefix" | tr -d '[:space:]')"
feed_signature='pjYf44eklLz1MVKhaKV6nZH4dA1c3kFDKxOpd6VJZvD0Jt7sgow0ldZJwDwS7axxSBmFW6p+CkSg6oNHVXLzBA=='
cp "$appcast_prefix" "$appcast_path"
printf '%s\n' \
    '<!-- sparkle-signatures:' \
    "edSignature: $feed_signature" \
    "length: $feed_length" \
    '-->' \
    >> "$appcast_path"
printf '%s\n' 'GX9rI+FshTLGq8g4+s1ep4m+DHaykgM0A5v6iz02jWE=' > "$public_key_path"
public_key="$(tr -d '\r\n' < "$public_key_path")"

cat > "$fake_verify_tool" <<'FAKE_VERIFY'
#!/bin/bash
set -euo pipefail
[ "$1" = "--verify" ]
[ "$2" = "--ed-key-file" ]
[ "$3" = "-" ]
case "$4" in
    "$EXPECTED_ARCHIVE")
        [ "$5" = "$EXPECTED_ARCHIVE_SIGNATURE" ]
        ;;
    "$EXPECTED_APPCAST")
        [ "$#" = "4" ]
        ;;
    *)
        exit 1
        ;;
esac
[ "$(cat)" = "$EXPECTED_PRIVATE_KEY" ]
printf '%s\n' "$4" >> "$FAKE_VERIFY_CALLS"
FAKE_VERIFY
chmod +x "$fake_verify_tool"

test_private_key='KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio='
printf '%s' "$test_private_key" \
    | EXPECTED_APPCAST="$appcast_path" \
      EXPECTED_ARCHIVE="$archive_path" \
      EXPECTED_ARCHIVE_SIGNATURE="$archive_signature" \
      EXPECTED_PRIVATE_KEY="$test_private_key" \
      FAKE_VERIFY_CALLS="$test_root/verify-calls.txt" \
      "$verify_script" \
        --appcast "$appcast_path" \
        --archive "$archive_path" \
        --tag v0.2.0 \
        --version 0.2.0 \
        --build 3 \
        --public-ed-key "$public_key" \
        --signature-verifier-tool "$signature_verifier" \
        --sign-update-tool "$fake_verify_tool"
test "$(wc -l < "$test_root/verify-calls.txt" | tr -d '[:space:]')" = "2" \
    || fail "official verification is not applied to both archive and feed"
grep -Fx -q "$archive_path" "$test_root/verify-calls.txt" \
    || fail "archive signature was not verified"
grep -Fx -q "$appcast_path" "$test_root/verify-calls.txt" \
    || fail "feed signature was not verified"

tampered_case="$test_root/tampered-case"
mkdir "$tampered_case"
tampered_archive="$tampered_case/CodexGauge.dmg"
tampered_appcast="$tampered_case/appcast.xml"
cp "$archive_path" "$tampered_archive"
cp "$appcast_path" "$tampered_appcast"
printf '%s\n' 'tampered' >> "$tampered_archive"
expect_failure "$verify_script" \
    --appcast "$tampered_appcast" \
    --archive "$tampered_archive" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$public_key" \
    --signature-verifier-tool "$signature_verifier"

same_length_archive_case="$test_root/same-length-archive-case"
mkdir "$same_length_archive_case"
same_length_archive="$same_length_archive_case/CodexGauge.dmg"
same_length_archive_appcast="$same_length_archive_case/appcast.xml"
copy_and_replace \
    "$archive_path" \
    "$same_length_archive" \
    'synthetic' \
    'Synthetic'
cp "$appcast_path" "$same_length_archive_appcast"
expect_failure "$verify_script" \
    --appcast "$same_length_archive_appcast" \
    --archive "$same_length_archive" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$public_key" \
    --signature-verifier-tool "$signature_verifier"

wrong_url_case="$test_root/wrong-url-case"
mkdir "$wrong_url_case"
wrong_url_appcast="$wrong_url_case/appcast.xml"
copy_and_replace \
    "$appcast_path" \
    "$wrong_url_appcast" \
    'releases/download/v0.2.0/CodexGauge.dmg' \
    'releases/latest/download/CodexGauge.dmg'
expect_failure "$verify_script" \
    --appcast "$wrong_url_appcast" \
    --archive "$archive_path" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$public_key" \
    --signature-verifier-tool "$signature_verifier"

same_length_feed_case="$test_root/same-length-feed-case"
mkdir "$same_length_feed_case"
same_length_feed_appcast="$same_length_feed_case/appcast.xml"
copy_and_replace \
    "$appcast_path" \
    "$same_length_feed_appcast" \
    '<title>Version 0.2.0</title>' \
    '<title>Release 0.2.0</title>'
expect_failure "$verify_script" \
    --appcast "$same_length_feed_appcast" \
    --archive "$archive_path" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$public_key" \
    --signature-verifier-tool "$signature_verifier"

forbidden_case="$test_root/forbidden-case"
mkdir "$forbidden_case"
forbidden_appcast="$forbidden_case/appcast.xml"
copy_and_replace \
    "$appcast_path" \
    "$forbidden_appcast" \
    '<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>' \
    '<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion><sparkle:channel>beta</sparkle:channel>'
expect_failure "$verify_script" \
    --appcast "$forbidden_appcast" \
    --archive "$archive_path" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$public_key" \
    --signature-verifier-tool "$signature_verifier"

delta_case="$test_root/delta-case"
mkdir "$delta_case"
delta_appcast="$delta_case/appcast.xml"
copy_and_replace \
    "$appcast_path" \
    "$delta_appcast" \
    'sparkle:edSignature=' \
    'sparkle:deltaFrom="2" sparkle:edSignature='
expect_failure "$verify_script" \
    --appcast "$delta_appcast" \
    --archive "$archive_path" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$public_key" \
    --signature-verifier-tool "$signature_verifier"

unsigned_case="$test_root/unsigned-case"
mkdir "$unsigned_case"
unsigned_appcast="$unsigned_case/appcast.xml"
sed '/<!-- sparkle-signatures:/,$d' "$appcast_path" > "$unsigned_appcast"
expect_failure "$verify_script" \
    --appcast "$unsigned_appcast" \
    --archive "$archive_path" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$public_key" \
    --signature-verifier-tool "$signature_verifier"

wrong_key='not-a-valid-public-key'
expect_failure "$verify_script" \
    --appcast "$appcast_path" \
    --archive "$archive_path" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$wrong_key" \
    --signature-verifier-tool "$signature_verifier"

wrong_valid_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
expect_failure "$verify_script" \
    --appcast "$appcast_path" \
    --archive "$archive_path" \
    --tag v0.2.0 \
    --version 0.2.0 \
    --build 3 \
    --public-ed-key "$wrong_valid_key" \
    --signature-verifier-tool "$signature_verifier"

generated_directory="$test_root/generated"
mkdir "$generated_directory"
cat > "$fake_tool" <<'FAKE_GENERATOR'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_ARGUMENTS"
[ "$(cat)" = "$FAKE_PRIVATE_KEY" ]
output=""
source_directory=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *)
            source_directory="$1"
            shift
            ;;
    esac
done
[ -f "$source_directory/CodexGauge.dmg" ]
[ "$(find "$source_directory" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" = "1" ]
cp "$FAKE_APPCAST" "$output"
FAKE_GENERATOR
chmod +x "$fake_tool"

FAKE_APPCAST="$appcast_path" \
FAKE_ARGUMENTS="$test_root/generate-arguments.txt" \
printf '%s' "$test_private_key" \
    | FAKE_APPCAST="$appcast_path" \
      FAKE_ARGUMENTS="$test_root/generate-arguments.txt" \
      FAKE_PRIVATE_KEY="$test_private_key" \
      "$generate_script" \
        --generate-appcast-tool "$fake_tool" \
        --archive "$archive_path" \
        --output "$generated_directory/appcast.xml" \
        --tag v0.2.0

cmp -s "$appcast_path" "$generated_directory/appcast.xml" \
    || fail "generator reformatted the signed appcast"
grep -Fx -q -- '--ed-key-file' "$test_root/generate-arguments.txt" \
    || fail "generator does not request an EdDSA key file"
grep -Fx -q -- '-' "$test_root/generate-arguments.txt" \
    || fail "generator does not read the EdDSA key from stdin"
grep -Fx -q -- '--maximum-versions' "$test_root/generate-arguments.txt" \
    || fail "generator does not limit preserved versions"
grep -Fx -q -- '1' "$test_root/generate-arguments.txt" \
    || fail "generator version limit is missing"
grep -Fx -q -- '--maximum-deltas' "$test_root/generate-arguments.txt" \
    || fail "generator does not disable deltas"
grep -Fx -q -- '0' "$test_root/generate-arguments.txt" \
    || fail "generator delta limit is missing"
grep -Fx -q -- 'https://github.com/symflee/codex-gauge/releases/download/v0.2.0/' \
    "$test_root/generate-arguments.txt" \
    || fail "generator does not use the immutable tag URL"

expect_failure "$generate_script" \
    --generate-appcast-tool "$fake_tool" \
    --archive "$archive_path" \
    --output "$generated_directory/appcast.xml" \
    --tag v0.2.0

echo "PASS release appcast scripts"
