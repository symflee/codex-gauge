#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: verify-release-appcast.sh --appcast <appcast.xml> --archive <CodexGauge.dmg> --tag <vX.Y.Z> --version <X.Y.Z> --build <number> --public-ed-key <base64> --signature-verifier-tool <path> [--sign-update-tool <path>]" >&2
}

fail() {
    echo "release appcast verification failed: $1" >&2
    exit 1
}

appcast_path=""
archive_path=""
release_tag=""
expected_version=""
expected_build=""
public_ed_key=""
signature_verifier_tool=""
sign_update_tool=""
metadata_root=""

cleanup() {
    local status="$?"
    local leaf_name=""

    trap - EXIT
    if [ -n "$metadata_root" ]; then
        leaf_name="$(basename "$metadata_root")"
        case "$leaf_name" in
            codex-gauge-appcast-verification.*)
                if [ -d "$metadata_root" ] && [ ! -L "$metadata_root" ]; then
                    rm -rf -- "$metadata_root"
                fi
                ;;
        esac
    fi
    exit "$status"
}

trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --appcast)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            appcast_path="$2"
            shift 2
            ;;
        --archive)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            archive_path="$2"
            shift 2
            ;;
        --tag)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            release_tag="$2"
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
        --public-ed-key)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            public_ed_key="$2"
            shift 2
            ;;
        --signature-verifier-tool)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            signature_verifier_tool="$2"
            shift 2
            ;;
        --sign-update-tool)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            sign_update_tool="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[ -n "$appcast_path" ] || { usage; exit 64; }
[ -n "$archive_path" ] || { usage; exit 64; }
[ -n "$release_tag" ] || { usage; exit 64; }
[ -n "$expected_version" ] || { usage; exit 64; }
[ -n "$expected_build" ] || { usage; exit 64; }
[ -n "$public_ed_key" ] || { usage; exit 64; }
[ -n "$signature_verifier_tool" ] || { usage; exit 64; }
[ -f "$appcast_path" ] && [ ! -L "$appcast_path" ] \
    || fail "appcast is invalid"
[ -f "$archive_path" ] && [ ! -L "$archive_path" ] \
    || fail "update archive is invalid"
[ "$(basename "$appcast_path")" = "appcast.xml" ] \
    || fail "appcast must be named appcast.xml"
[ "$(basename "$archive_path")" = "CodexGauge.dmg" ] \
    || fail "update archive must be named CodexGauge.dmg"
printf '%s\n' "$expected_version" \
    | grep -E -q '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || fail "version must use X.Y.Z"
[ "$release_tag" = "v$expected_version" ] \
    || fail "tag and version do not match"
printf '%s\n' "$expected_build" | grep -E -q '^[1-9][0-9]*$' \
    || fail "build must be a positive integer"
ruby -rbase64 -e '
  key = Base64.strict_decode64(ARGV.fetch(0))
  exit(key.bytesize == 32 ? 0 : 1)
' "$public_ed_key" >/dev/null 2>&1 \
    || fail "public EdDSA key is invalid"
[ -f "$signature_verifier_tool" ] && [ -x "$signature_verifier_tool" ] \
    && [ ! -L "$signature_verifier_tool" ] \
    || fail "public signature verifier is invalid"

metadata_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-gauge-appcast-verification.XXXXXX")"
metadata_path="$metadata_root/metadata"
archive_length="$(wc -c < "$archive_path" | tr -d '[:space:]')"
expected_url="https://github.com/symflee/codex-gauge/releases/download/$release_tag/CodexGauge.dmg"

if ! ruby -rbase64 -rrexml/document - "$appcast_path" "$metadata_path" \
    "$expected_url" "$expected_version" "$expected_build" "$archive_length" <<'RUBY'
appcast_path, metadata_path, expected_url, expected_version, expected_build,
  expected_length = ARGV
raw = File.binread(appcast_path)
exit(1) if raw.include?("<!DOCTYPE") || raw.include?("<!ENTITY")
footer = raw.match(/<!-- sparkle-signatures:\s*\nedSignature: ([A-Za-z0-9+\/=]+)\s*\nlength: ([0-9]+)\s*\n-->\s*\z/m)
exit(1) unless footer
feed_signature = footer[1]
feed_length = Integer(footer[2], 10)
exit(1) unless feed_length == footer.begin(0)
exit(1) unless Base64.strict_decode64(feed_signature).bytesize == 64

document = REXML::Document.new(raw)
namespace = { "sparkle" => "http://www.andymatuschak.org/xml-namespaces/sparkle" }
items = REXML::XPath.match(document, "/rss/channel/item")
exit(1) unless items.length == 1
item = items.fetch(0)
enclosures = REXML::XPath.match(item, "enclosure")
exit(1) unless enclosures.length == 1
enclosure = enclosures.fetch(0)
versions = REXML::XPath.match(item, "sparkle:version", namespace)
short_versions = REXML::XPath.match(
  item,
  "sparkle:shortVersionString",
  namespace
)
minimum_systems = REXML::XPath.match(
  item,
  "sparkle:minimumSystemVersion",
  namespace
)
exit(1) unless versions.length == 1
exit(1) unless short_versions.length == 1
exit(1) unless minimum_systems.length == 1
version = versions.fetch(0).text&.strip
short_version = short_versions.fetch(0).text&.strip
minimum_system = minimum_systems.fetch(0).text&.strip
exit(1) unless version == expected_build
exit(1) unless short_version == expected_version
exit(1) unless minimum_system == "13.0"
exit(1) unless enclosure.attributes["url"] == expected_url
exit(1) unless enclosure.attributes["length"] == expected_length
exit(1) unless enclosure.attributes["type"] == "application/octet-stream"
archive_signature = enclosure.attributes["sparkle:edSignature"]
exit(1) unless archive_signature
exit(1) unless Base64.strict_decode64(archive_signature).bytesize == 64
exit(1) if enclosure.attributes["deltaFrom"]

forbidden = %w[
  channel phasedRolloutInterval criticalUpdate minimumAutoupdateVersion
  minimumUpdateVersion informationalUpdate deltas deltaFrom releaseNotesLink
]
forbidden.each do |name|
  exit(1) unless REXML::XPath.match(item, ".//sparkle:#{name}", namespace).empty?
end
exit(1) unless REXML::XPath.match(item, "description").empty?
File.write(metadata_path, "#{archive_signature}\n#{feed_signature}\n#{feed_length}\n")
RUBY
then
    fail "appcast structure does not match the release contract"
fi

archive_signature="$(sed -n '1p' "$metadata_path")"
feed_signature="$(sed -n '2p' "$metadata_path")"
feed_length="$(sed -n '3p' "$metadata_path")"
"$signature_verifier_tool" \
    "$archive_path" \
    "$archive_signature" \
    "$public_ed_key" \
    || fail "public-key verification rejected the update archive"
"$signature_verifier_tool" \
    "$appcast_path" \
    "$feed_signature" \
    "$public_ed_key" \
    "$feed_length" \
    || fail "public-key verification rejected the appcast"

if [ -n "$sign_update_tool" ]; then
    [ -f "$sign_update_tool" ] && [ -x "$sign_update_tool" ] \
        && [ ! -L "$sign_update_tool" ] \
        || fail "sign_update tool is invalid"
    private_ed_key="$(cat)"
    [ -n "$private_ed_key" ] || fail "private EdDSA key is empty"
    if ! printf '%s' "$private_ed_key" | "$sign_update_tool" \
        --verify \
        --ed-key-file - \
        "$archive_path" \
        "$archive_signature" \
        >/dev/null 2>&1; then
        unset private_ed_key
        fail "Sparkle sign_update rejected the update archive"
    fi
    if ! printf '%s' "$private_ed_key" | "$sign_update_tool" \
        --verify \
        --ed-key-file - \
        "$appcast_path" \
        >/dev/null 2>&1; then
        unset private_ed_key
        fail "Sparkle sign_update rejected the appcast"
    fi
    unset private_ed_key
fi

echo "PASS release appcast verification"
