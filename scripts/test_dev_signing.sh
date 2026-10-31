#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${TOUCHBRIDGE_CONFIG_DIR:-${HOME}/Library/Application Support/TouchBridge/Development}"
IDENTITY="${TOUCHBRIDGE_SIGNING_IDENTITY:-$(cat "$CONFIG_DIR/signing-identity.sha1")}"
SOURCE_APP="$REPO_ROOT/build/dev/TouchBridge Dev.app"
[ -d "$SOURCE_APP" ] || { echo 'Build the development app first.' >&2; exit 1; }
TEST_DIR="$(mktemp -d "$REPO_ROOT/build/signing-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Compile distinct executables so this tests a source rebuild, not merely signing
# the same binary twice. Never launch these bundles or request a privacy grant.
for version in 1 2; do
    app="$TEST_DIR/v$version.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$SOURCE_APP/Contents/Info.plist" "$app/Contents/Info.plist"
    printf 'print("signing regression version %s")\n' "$version" > "$TEST_DIR/main.swift"
    swiftc "$TEST_DIR/main.swift" -o "$app/Contents/MacOS/TouchBridge Dev"
    codesign --force --sign "$IDENTITY" --timestamp=none "$app"
    codesign --verify --strict "$app"
    codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p' > "$TEST_DIR/v$version.requirement"
    codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p' > "$TEST_DIR/v$version.hash"
    [ -s "$TEST_DIR/v$version.hash" ]
done
! cmp -s "$TEST_DIR/v1.hash" "$TEST_DIR/v2.hash"
cmp "$TEST_DIR/v1.requirement" "$TEST_DIR/v2.requirement"
requirement="$(cat "$TEST_DIR/v1.requirement")"
[ -n "$requirement" ] && [[ "$requirement" != *cdhash* ]]
codesign --verify --strict -R "=$requirement" "$TEST_DIR/v2.app"
echo 'PASS: Different compiled code hashes retain and satisfy the same certificate-based requirement.'

# Control: the inherited ad-hoc method cannot survive the same source rebuild.
for version in 1 2; do codesign --force --sign - "$TEST_DIR/v$version.app"; done
adhoc_requirement="$(codesign -d -r- "$TEST_DIR/v1.app" 2>&1 | sed -n 's/^# designated => //p')"
[ -n "$adhoc_requirement" ] && [[ "$adhoc_requirement" == *cdhash* ]]
if codesign --verify --strict -R "=$adhoc_requirement" "$TEST_DIR/v2.app"; then
    echo 'FAIL: Different ad-hoc build unexpectedly satisfied the old requirement.' >&2
    exit 1
fi
echo 'PASS: Ad-hoc control rejects the changed build under the old requirement.'

# Tampering must fail: stable identity must not weaken resource validation.
codesign --force --sign "$IDENTITY" --timestamp=none "$TEST_DIR/v2.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion tampered' "$TEST_DIR/v2.app/Contents/Info.plist"
if codesign --verify --strict "$TEST_DIR/v2.app"; then
    echo 'FAIL: Tampered bundle validated.' >&2
    exit 1
fi
echo 'PASS: Tampered bundle is rejected.'
