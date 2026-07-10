#!/usr/bin/env bash
# App Store screenshot automation (plan 23).
#
# One command, idempotent:
#   ./scripts/screenshots.sh
#
# Runs AppUITests/ScreenshotTests (skipped in normal test runs; enabled here
# via TEST_RUNNER_SCREENSHOT_MODE=1) over the deterministic --demo-data
# fixture on each target simulator, then extracts the full-screen PNG
# attachments from the xcresult into docs/app-store/screenshots/ named
# <device-slug>-<nn>-<name>.png.
#
# Device classes (verified against Apple's screenshot specifications,
# https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/
# fetched 2026-07-09):
#   - 6.9" (1260x2736, iPhone 17 Pro Max class) — REQUIRED.
#   - 6.5" (1284x2778) — only a FALLBACK slot used when no 6.9" set exists;
#     no 6.5"-class device can run the iOS 26 simulator runtime (that class
#     ended with iPhone 14 Plus), so providing the 6.9" set satisfies App
#     Store Connect and the 6.5" slot is left to ASC's automatic scaling.
#   - 6.3" (iPhone 17 class) — optional, captured as a nice-to-have.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICES=("iPhone 17 Pro Max" "iPhone 17")
OUT_DIR="docs/app-store/screenshots"
SCHEME="DispatchApp"

if ! [ -d Dispatch.xcodeproj ]; then
  xcodegen generate
fi

mkdir -p "$OUT_DIR"

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//'
}

for DEVICE in "${DEVICES[@]}"; do
  SLUG="$(slugify "$DEVICE")"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-screenshots-XXXXXX")"
  RESULT="$WORK/screenshots.xcresult"

  echo "==> Capturing on $DEVICE"
  xcodebuild test \
    -project Dispatch.xcodeproj \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -only-testing:DispatchUITests/ScreenshotTests \
    -resultBundlePath "$RESULT" \
    TEST_RUNNER_SCREENSHOT_MODE=1 \
    | tail -5

  echo "==> Extracting attachments from $RESULT"
  EXPORT_DIR="$WORK/attachments"
  mkdir -p "$EXPORT_DIR"
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$EXPORT_DIR"

  # manifest.json maps exported files back to attachment names; keep only our
  # "shot-<nn>-<name>" captures and write <device-slug>-<nn>-<name>.png.
  python3 - "$EXPORT_DIR" "$OUT_DIR" "$SLUG" <<'PY'
import json, pathlib, shutil, sys

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
    dest = out_dir / f"{slug}-{shot}.png"
    shutil.copyfile(export_dir / exported, dest)
    copied += 1
    print(f"    {dest}")
if copied == 0:
    sys.exit("no shot-* attachments found in xcresult — did the tests run?")
PY

  rm -rf "$WORK"
done

echo "==> Done. Screenshots in $OUT_DIR/"
ls -1 "$OUT_DIR"
