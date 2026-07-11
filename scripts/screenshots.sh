#!/usr/bin/env bash
# App Store screenshot automation (plan 23; extended to iPad/watch/Mac).
#
# One command, idempotent:
#   ./scripts/screenshots.sh
#
# Runs the SCREENSHOT_MODE-gated screenshot suites (skipped in normal test
# runs; enabled here via TEST_RUNNER_SCREENSHOT_MODE=1) over the deterministic
# --demo-data fixture on each target simulator (and the local Mac), then
# extracts the full-screen PNG attachments from each xcresult into
# docs/app-store/screenshots/ named <device-slug>-<nn>-<name>.png.
#
# Every shot uses a DIFFERENT app theme (the original Reporter listing look):
# the suites relaunch the app per shot with `--theme <name>` cycling the
# palette. The watch app has no theme system, so watch shots are unthemed.
#
# Device classes (verified against Apple's screenshot specifications and the
# ASC OpenAPI spec's ScreenshotDisplayType enum, fetched 2026-07-11):
#   - 6.9" (iPhone 17 Pro Max; 1320x2868) → APP_IPHONE_67 — REQUIRED.
#   - 6.3" (iPhone 17; 1206x2622) → APP_IPHONE_61 — optional nice-to-have.
#   - 13"  (iPad Pro 13-inch (M5); 2064x2752) → APP_IPAD_PRO_3GEN_129.
#   - watch (Apple Watch Ultra 3; 422x514) → APP_WATCH_ULTRA.
#   - Mac (1440x900-pt window, 16:10) → APP_DESKTOP.
set -euo pipefail

cd "$(dirname "$0")/.."

IOS_DEVICES=("iPhone 17 Pro Max" "iPhone 17" "iPad Pro 13-inch (M5)")
WATCH_DEVICE="Apple Watch Ultra 3 (49mm)"
OUT_DIR="docs/app-store/screenshots"

if ! [ -d Dispatch.xcodeproj ]; then
  xcodegen generate
fi

mkdir -p "$OUT_DIR"
# The rig is authoritative for this directory: wipe first so renamed/removed
# shots never leave stale files behind (the dir is gitignored, output only).
rm -f "$OUT_DIR"/*.png

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//'
}

# extract <xcresult> <device-slug> — pull the shot-* attachments out of the
# result bundle into $OUT_DIR/<device-slug>-<nn>-<name>.png.
extract() {
  local RESULT="$1" SLUG="$2"
  local EXPORT_DIR
  EXPORT_DIR="$(dirname "$RESULT")/attachments"
  echo "==> Extracting attachments from $RESULT"
  mkdir -p "$EXPORT_DIR"
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$EXPORT_DIR"

  # manifest.json maps exported files back to attachment names; keep only our
  # "shot-<nn>-<name>" captures and write <device-slug>-<nn>-<name>.png.
  python3 - "$EXPORT_DIR" "$OUT_DIR" "$SLUG" <<'PY'
import json, pathlib, re, shutil, sys

export_dir = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
slug = sys.argv[3]
manifest = json.loads((export_dir / "manifest.json").read_text())

# Walk the manifest recursively — the exact nesting has shifted between
# Xcode releases; any dict carrying exportedFileName is an attachment.
def attachments(node):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            yield from attachments(value)
    elif isinstance(node, list):
        for item in node:
            yield from attachments(item)

copied = 0
for att in attachments(manifest):
    name = att.get("suggestedHumanReadableName") or att.get("exportedFileName") or ""
    exported = att["exportedFileName"]
    if "shot-" not in name:
        continue
    shot = name.split("shot-", 1)[1]
    for ext in (".png", ".jpeg", ".jpg"):
        shot = shot.removesuffix(ext)
    # xcresulttool appends "_<n>_<UUID>" to suggested names — strip it.
    shot = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", shot)
    dest = out_dir / f"{slug}-{shot}.png"
    shutil.copyfile(export_dir / exported, dest)
    copied += 1
    print(f"    {dest}")
if copied == 0:
    sys.exit("no shot-* attachments found in xcresult — did the tests run?")
PY
}

# --- iPhone + iPad ----------------------------------------------------------
for DEVICE in "${IOS_DEVICES[@]}"; do
  SLUG="$(slugify "$DEVICE")"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-screenshots-XXXXXX")"
  RESULT="$WORK/screenshots.xcresult"

  echo "==> Capturing on $DEVICE"
  # TEST_RUNNER_* must be in xcodebuild's ENVIRONMENT (not a build setting)
  # to reach the test runner's process environment with the prefix stripped.
  env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test \
    -project Dispatch.xcodeproj \
    -scheme DispatchApp \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -only-testing:DispatchUITests/ScreenshotTests \
    -resultBundlePath "$RESULT" \
    | tail -5

  extract "$RESULT" "$SLUG"
  rm -rf "$WORK"
done

# --- Apple Watch --------------------------------------------------------------
SLUG="$(slugify "$WATCH_DEVICE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-screenshots-XXXXXX")"
RESULT="$WORK/screenshots.xcresult"
echo "==> Capturing on $WATCH_DEVICE"
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test \
  -project Dispatch.xcodeproj \
  -scheme DispatchWatch \
  -destination "platform=watchOS Simulator,name=$WATCH_DEVICE" \
  -only-testing:DispatchWatchUITests/WatchScreenshotTests \
  -resultBundlePath "$RESULT" \
  | tail -5
extract "$RESULT" "$SLUG"
rm -rf "$WORK"

# --- Mac ----------------------------------------------------------------------
# Runs on the local Mac (no simulator). The app launches test-gated
# (--ui-testing → in-memory store, sync off, demo fixture) and pins its window
# to 1440x900 points — a 16:10 frame that lands on an ASC-accepted pixel size
# at both 1x (1440x900) and 2x/Retina (2880x1800).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-screenshots-XXXXXX")"
RESULT="$WORK/screenshots.xcresult"
echo "==> Capturing on Mac (DispatchMac)"
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test \
  -project Dispatch.xcodeproj \
  -scheme DispatchMac \
  -destination "platform=macOS" \
  -only-testing:DispatchMacUITests/MacScreenshotTests \
  -resultBundlePath "$RESULT" \
  | tail -5
extract "$RESULT" "mac"
rm -rf "$WORK"

echo "==> Done. Screenshots in $OUT_DIR/"
ls -1 "$OUT_DIR"
