#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/assets/screenshots}"
APP_BIN="$ROOT_DIR/.build/debug/macmtp"
APP_PROCESS_NAME="macmtp"

pages=(
  ${MACMTP_SCREENSHOT_PAGES:-main preferences help about transfer conflict}
)

mkdir -p "$OUTPUT_DIR"

cd "$ROOT_DIR"
swift build

capture_page() {
  local page="$1"
  local output_file="$OUTPUT_DIR/macmtp-${page}.png"
  local app_pid

  defaults write com.macmtp.app MACMTPScreenshotMode -bool YES
  defaults write com.macmtp.app MACMTPScreenshotPage "$page"
  MACMTP_SCREENSHOT_MODE=1 MACMTP_SCREENSHOT_PAGE="$page" "$APP_BIN" --screenshot-mode --screenshot-page "$page" &
  app_pid="$!"

  local rect=""
  for _ in {1..50}; do
    rect="$(swift - "$app_pid" <<'SWIFT'
import CoreGraphics
import Foundation

let processID = Int(CommandLine.arguments[1]) ?? -1
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

let matches = windows.compactMap { window -> (area: Double, rect: CGRect)? in
    guard (window[kCGWindowOwnerPID as String] as? Int) == processID,
          (window[kCGWindowLayer as String] as? Int) == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? Double,
          let y = bounds["Y"] as? Double,
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width > 100,
          height > 100 else {
        return nil
    }
    return (width * height, CGRect(x: x, y: y, width: width, height: height))
}

guard let match = matches.max(by: { $0.area < $1.area }) else {
    exit(2)
}
let rect = match.rect.integral
print("\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.size.width)),\(Int(rect.size.height))")
SWIFT
)" && [[ -n "$rect" ]] && break
    sleep 0.2
  done

  if [[ -z "$rect" ]]; then
    echo "Timed out waiting for $APP_PROCESS_NAME window for page $page" >&2
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    return 1
  fi

  osascript -e 'tell application "macmtp" to activate' >/dev/null 2>&1 || true
  sleep 0.8
  screencapture -x -R"$rect" "$output_file"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  defaults delete com.macmtp.app MACMTPScreenshotMode >/dev/null 2>&1 || true
  defaults delete com.macmtp.app MACMTPScreenshotPage >/dev/null 2>&1 || true

  echo "$output_file"
}

for page in "${pages[@]}"; do
  capture_page "$page"
done
