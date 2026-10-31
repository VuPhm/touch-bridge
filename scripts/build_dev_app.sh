#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_NAME="TouchBridge Dev.app"
BUNDLE_ID="com.antigravity.touchbridge.dev"
BUILD_DIR="${REPO_ROOT}/build/dev"
CONFIG_DIR="${TOUCHBRIDGE_CONFIG_DIR:-${HOME}/Library/Application Support/TouchBridge/Development}"
IDENTITY_FILE="${CONFIG_DIR}/signing-identity.sha1"
INSTALL_REQUESTED=false
RESTART=false
CLEAN_BUILD=false

fail() { echo "[ERROR] $*" >&2; exit 1; }
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_REQUESTED=true ;;
        --restart) RESTART=true ;;
        --clean) CLEAN_BUILD=true ;;
        --help|-h)
            cat <<'HELP'
Usage: ./scripts/build_dev_app.sh [--install] [--restart] [--clean]
  --install  Safely replace ~/Applications/TouchBridge Dev.app; retain a backup.
  --restart  With --install, quit the installed app after staging, then relaunch.
  --clean    Explicitly clean SwiftPM artifacts before building.

Uses a persistent Keychain signing identity; never falls back to ad-hoc signing.
On first use, selects the sole valid identity (preferring TouchBridge Dev Local Signing).
To choose explicitly, set TOUCHBRIDGE_SIGNING_IDENTITY to its 40-character SHA-1.
The successful choice is pinned in ~/Library/Application Support/TouchBridge/Development/.
See DEVELOPMENT_SIGNING.md for local certificate setup and permission diagnostics.
HELP
            exit 0 ;;
        *) fail "Unknown option: $arg" ;;
    esac
done
if [ "$RESTART" = true ] && [ "$INSTALL_REQUESTED" != true ]; then
    fail "--restart requires --install"
fi
cd "$REPO_ROOT"

# Resolve once, then pin the exact certificate. A locked/missing/expired identity
# must fail closed, never silently turn a daily-driver app back into ad-hoc code.
IDENTITIES="$(security find-identity -v -p codesigning)"
SIGNING_IDENTITY="${TOUCHBRIDGE_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ] && [ -f "$IDENTITY_FILE" ]; then
    SIGNING_IDENTITY="$(cat "$IDENTITY_FILE")"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    CANDIDATES="$(printf '%s\n' "$IDENTITIES" | awk '/"TouchBridge Dev Local Signing"$/ {print $2}')"
    if [ -z "$CANDIDATES" ]; then
        CANDIDATES="$(printf '%s\n' "$IDENTITIES" | awk '/^[[:space:]]*[0-9]+\)/ {print $2}')"
    fi
    [ "$(printf '%s\n' "$CANDIDATES" | awk 'NF {n++} END {print n+0}')" = 1 ] ||
        fail "Choose a persistent signing identity. Run security find-identity -v -p codesigning; see DEVELOPMENT_SIGNING.md."
    SIGNING_IDENTITY="$CANDIDATES"
fi
[[ "$SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] || fail "Signing identity must be a certificate SHA-1, not '-' or a name."
SIGNING_IDENTITY="$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')"
printf '%s\n' "$IDENTITIES" | awk -v hash="$SIGNING_IDENTITY" '$2 == hash {found=1} END {exit !found}' ||
    fail "Pinned identity $SIGNING_IDENTITY is unavailable. Unlock the Keychain or restore that identity; installed app is untouched."

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
BUILD_TIMESTAMP="$(date -u '+%Y%m%d%H%M%S')"
VERSION_STRING="1.0.0 (${GIT_SHA})"
mkdir -p "$BUILD_DIR"
STAGE="$(mktemp -d "${BUILD_DIR}/.stage.XXXXXX")"
INSTALL_STAGE=""
cleanup() {
    rm -rf "$STAGE"
    if [ -n "$INSTALL_STAGE" ]; then rm -rf "$INSTALL_STAGE"; fi
}
trap cleanup EXIT
APP_BUNDLE="${STAGE}/${BUNDLE_NAME}"

echo "Signing certificate: $SIGNING_IDENTITY"
if [ "$CLEAN_BUILD" = true ]; then swift package clean; fi
swift build -c release
RELEASE_BIN="${REPO_ROOT}/.build/release/TouchBridgeProbe"
[ -x "$RELEASE_BIN" ] || fail "Release binary missing: $RELEASE_BIN"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/TouchBridge Dev"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>TouchBridge Dev</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>TouchBridge</string>
    <key>CFBundleDisplayName</key><string>TouchBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION_STRING}</string>
    <key>CFBundleVersion</key><string>${BUILD_TIMESTAMP}</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAccessibilityUsageDescription</key><string>TouchBridge requires Accessibility permissions to route touch interactions and perform native scrolling.</string>
</dict></plist>
PLIST
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
REQUIREMENT="$(codesign -d -r- "$APP_BUNDLE" 2>&1 | sed -n 's/^designated => //p')"
[ -n "$REQUIREMENT" ] || fail "Missing persistent designated requirement."
[[ "$REQUIREMENT" != *cdhash* ]] || fail "Refusing a code-hash-dependent designated requirement."

# Replace only fully verified bundles. The old copy is moved, never deleted.
# If publication fails, restore it immediately; retain backups after success.
publish_bundle() {
    local candidate="$1" destination="$2" backup=""
    if [ -e "$destination" ]; then
        local backup_dir
        backup_dir="$(mktemp -d "$(dirname "$destination")/.touchbridge-backup.XXXXXX")"
        backup="${backup_dir}/${BUNDLE_NAME}"
        mv "$destination" "$backup"
    fi
    if ! mv "$candidate" "$destination"; then
        if [ -n "$backup" ]; then mv "$backup" "$destination"; fi
        fail "Could not publish $destination; previous app restored where possible. Backup: $backup"
    fi
    if [ -n "$backup" ]; then echo "Previous app retained: $backup"; fi
}

if [ "$INSTALL_REQUESTED" = true ]; then
    INSTALL_DIR="${HOME}/Applications"
    INSTALLED_APP="${INSTALL_DIR}/${BUNDLE_NAME}"
    mkdir -p "$INSTALL_DIR"
    INSTALL_STAGE="$(mktemp -d "${INSTALL_DIR}/.touchbridge-stage.XXXXXX")"
    ditto "$APP_BUNDLE" "$INSTALL_STAGE/$BUNDLE_NAME"
    codesign --verify --strict --verbose=2 "$INSTALL_STAGE/$BUNDLE_NAME"
    # Refuse unintended identity changes after the first certificate-based install.
    if [ -d "$INSTALLED_APP" ]; then
        OLD_REQUIREMENT="$(codesign -d -r- "$INSTALLED_APP" 2>&1 | sed -n 's/^designated => //p')"
        if [ -n "$OLD_REQUIREMENT" ] && [[ "$OLD_REQUIREMENT" != *cdhash* ]]; then
            codesign --verify --strict -R "=$OLD_REQUIREMENT" "$INSTALL_STAGE/$BUNDLE_NAME" ||
                fail "New app does not satisfy the installed app's identity. See DEVELOPMENT_SIGNING.md; installed copy preserved."
        else
            echo "One-time migration from ad-hoc signing: macOS may require re-authorizing this installed app."
        fi
    fi
fi

# Persist only after signing and all preflight checks succeeded; no private keys here.
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$SIGNING_IDENTITY" > "${IDENTITY_FILE}.tmp.$$"
mv "${IDENTITY_FILE}.tmp.$$" "$IDENTITY_FILE"
if [ "$INSTALL_REQUESTED" = true ]; then
    if [ "$RESTART" = true ]; then
        swift "$SCRIPT_DIR/dev_app_lifecycle.swift" quit "$INSTALLED_APP"
    else
        swift "$SCRIPT_DIR/dev_app_lifecycle.swift" require-stopped "$INSTALLED_APP"
    fi
    publish_bundle "$INSTALL_STAGE/$BUNDLE_NAME" "$INSTALLED_APP"
fi
publish_bundle "$APP_BUNDLE" "$BUILD_DIR/$BUNDLE_NAME"
printf '%s\n' "$REQUIREMENT" > "$BUILD_DIR/designated-requirement.txt"
echo "Designated requirement: $REQUIREMENT"
echo "Built: $BUILD_DIR/$BUNDLE_NAME"
if [ "$INSTALL_REQUESTED" = true ]; then
    echo "Installed: $INSTALLED_APP"
    ZIP_ARCHIVE="${BUILD_DIR}/TouchBridge-v1.0.0.zip"
    ditto -c -k --sequesterRsrc --keepParent "$INSTALLED_APP" "$ZIP_ARCHIVE"
    echo "Archive: $ZIP_ARCHIVE"
    if [ "$RESTART" = true ]; then open "$INSTALLED_APP"; fi
    echo "Launch: open \"$INSTALLED_APP\""
else
    echo "Use --install to keep the authorized daily-driver path stable."
fi
