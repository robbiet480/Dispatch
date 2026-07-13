#!/bin/zsh
# Archive Dispatch and upload it to TestFlight, headlessly.
#
#   ./scripts/upload-testflight.sh [--mac|--mac-only] [notes-file.md]
#
# BEFORE YOU CUT A BUILD — release checklist:
#   1. Bump CURRENT_PROJECT_VERSION across all targets in project.yml.
#   2. Add scripts/notes-build<N>.md ("What to Test").
#   3. If this build carries any change to a CloudKit-mirrored @Model
#      (DispatchStore.allModels), DEPLOY THE CLOUDKIT SCHEMA FIRST — an
#      undeployed field makes every export fail with CKError.partialFailure and
#      silently breaks sync. Confirm Production is current:
#        python3 scripts/cloudkit_schema.py verify-production \
#          --team-id UTQFCBPQRF --container-id iCloud.io.robbie.Dispatch
#      (must print "up to date"; if not, see docs/cloudkit-schema.md to deploy).
#
# Default uploads the iOS app (which embeds watch + widgets). --mac ALSO
# archives and uploads the DispatchMac target; --mac-only skips iOS.
# The Mac lane signs MANUALLY: Apple Distribution + "Dispatch macOS App
# Store" profile (created via the ASC API on the shared io.robbie.Dispatch
# bundle id) + the 3rd Party Mac Developer Installer identity for the pkg —
# see scripts/ExportOptionsUploadMac.plist.
#
# Credentials: an App Store Connect API key (App Manager role). The .p8 lives
# in ~/.appstoreconnect/private_keys/ (auto-discovered by Apple's tooling);
# the key/issuer IDs are read from scripts/asc-config.local (gitignored —
# this is a public repo, IDs stay out of it).
#
#   scripts/asc-config.local:
#     ASC_KEY_ID=...
#     ASC_ISSUER_ID=...
set -euo pipefail
cd "$(dirname "$0")/.."

DO_IOS=1
DO_MAC=0
NOTES_FILE=""
for arg in "$@"; do
  case "$arg" in
    --mac) DO_MAC=1 ;;
    --mac-only) DO_MAC=1; DO_IOS=0 ;;
    *) NOTES_FILE="$arg" ;;
  esac
done

source scripts/asc-config.local
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[[ -f "$KEY_PATH" ]] || { echo "missing API key at $KEY_PATH" >&2; exit 1; }

AUTH_FLAGS=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

xcodegen generate

if [[ $DO_IOS -eq 1 ]]; then
  ARCHIVE_PATH="build/Dispatch.xcarchive"
  rm -rf "$ARCHIVE_PATH"

  xcodebuild archive \
    -project Dispatch.xcodeproj \
    -scheme DispatchApp \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    "${AUTH_FLAGS[@]}" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM=UTQFCBPQRF \
    | tail -3

  # ExportOptions destination=upload sends the build to App Store Connect
  # as part of the export step — no separate altool/Transporter pass.
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist scripts/ExportOptionsUpload.plist \
    "${AUTH_FLAGS[@]}" \
    | tail -5

  echo "iOS upload done."
fi

if [[ $DO_MAC -eq 1 ]]; then
  MAC_ARCHIVE_PATH="build/DispatchMac.xcarchive"
  rm -rf "$MAC_ARCHIVE_PATH"

  # Manual signing: automatic signing headlessly picks a development identity
  # for macOS and the export then fails; the profile is pinned instead
  # (plan-25 watch-profile precedent).
  xcodebuild archive \
    -project Dispatch.xcodeproj \
    -scheme DispatchMac \
    -destination 'generic/platform=macOS' \
    -archivePath "$MAC_ARCHIVE_PATH" \
    "${AUTH_FLAGS[@]}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="Dispatch macOS App Store" \
    DEVELOPMENT_TEAM=UTQFCBPQRF \
    | tail -3

  xcodebuild -exportArchive \
    -archivePath "$MAC_ARCHIVE_PATH" \
    -exportOptionsPlist scripts/ExportOptionsUploadMac.plist \
    "${AUTH_FLAGS[@]}" \
    | tail -5

  echo "macOS upload done."
fi

echo "Uploaded. Builds appear in TestFlight after App Store Connect finishes processing (usually 5-15 minutes)."

# Optional: pass a what-to-test notes file — waits for processing, then sets
# the TestFlight "What to Test" text on EVERY platform build with this number.
if [[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]]; then
  BUILD_NUMBER=$(grep -m1 "CURRENT_PROJECT_VERSION" project.yml | awk '{print $2}')
  swift scripts/tf-notes.swift "$BUILD_NUMBER" "$NOTES_FILE"
fi
