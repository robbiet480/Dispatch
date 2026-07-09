#!/bin/zsh
# Archive Dispatch and upload it to TestFlight, headlessly.
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

source scripts/asc-config.local
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[[ -f "$KEY_PATH" ]] || { echo "missing API key at $KEY_PATH" >&2; exit 1; }

ARCHIVE_PATH="build/Dispatch.xcarchive"
rm -rf "$ARCHIVE_PATH"

xcodegen generate

xcodebuild archive \
  -project Dispatch.xcodeproj \
  -scheme DispatchApp \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=UTQFCBPQRF \
  | tail -3

# ExportOptions destination=upload sends the build to App Store Connect
# as part of the export step — no separate altool/Transporter pass.
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist scripts/ExportOptionsUpload.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  | tail -5

echo "Uploaded. The build appears in TestFlight after App Store Connect finishes processing (usually 5-15 minutes)."
