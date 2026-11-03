#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/.build/release/TouchBridgeProbe"
OUT_DIR="${REPO_ROOT}/docs/images"
mkdir -p "$OUT_DIR"

ORIGINAL_DARK_MODE="$(osascript -e 'tell application "System Events" to tell appearance preferences to return dark mode')"

cleanup() {
    echo "Restoring original appearance mode: dark mode = $ORIGINAL_DARK_MODE"
    osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $ORIGINAL_DARK_MODE"
}
trap cleanup EXIT

capture_tab() {
    local tab_idx="$1"
    local mode_name="$2"
    local filename="$3"

    echo "Capturing Tab $tab_idx in $mode_name mode..."
    # Launch preview binary with specific tab and short timeout
    "$BIN" --preview-settings --tab "$tab_idx" --duration 4 &
    local APP_PID=$!
    sleep 1.2

    # Get window bounds
    local BOUNDS
    BOUNDS="$(swift -e '
import Cocoa
import CoreGraphics
let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
for w in windowList {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if owner.contains("TouchBridge") {
        let boundsDict = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let h = boundsDict["Height"] as? CGFloat ?? 0
        let w = boundsDict["Width"] as? CGFloat ?? 0
        if h > 300 && w > 400 {
            let x = boundsDict["X"] as? CGFloat ?? 0
            let y = boundsDict["Y"] as? CGFloat ?? 0
            print("\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))")
            exit(0)
        }
    }
}
exit(1)
' 2>/dev/null || echo "")"

    if [ -n "$BOUNDS" ]; then
        echo "Window found at $BOUNDS. Capturing..."
        screencapture -R "$BOUNDS" "${OUT_DIR}/${filename}.png"
        sips -s format jpeg -s formatOptions 85 "${OUT_DIR}/${filename}.png" --out "${OUT_DIR}/${filename}.jpg" >/dev/null 2>&1
        sips -Z 1200 "${OUT_DIR}/${filename}.jpg" >/dev/null 2>&1
        rm -f "${OUT_DIR}/${filename}.png"
        echo "Saved: ${OUT_DIR}/${filename}.jpg"
    else
        echo "[WARNING] Window not found for tab $tab_idx"
    fi

    wait "$APP_PID" 2>/dev/null || true
    sleep 0.5
}

# 1. Dark Mode captures
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'
sleep 0.5
capture_tab 0 "Dark" "tab0_overview_dark"
capture_tab 1 "Dark" "tab1_touch_dark"
capture_tab 2 "Dark" "tab2_display_dark"
capture_tab 3 "Dark" "tab3_diagnostics_dark"

# 2. Light Mode captures
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false'
sleep 0.5
capture_tab 0 "Light" "tab0_overview_light"
capture_tab 1 "Light" "tab1_touch_light"
capture_tab 2 "Light" "tab2_display_light"
capture_tab 3 "Light" "tab3_diagnostics_light"

echo "UI verification captures complete."
ls -lh "${OUT_DIR}"/tab*.jpg
