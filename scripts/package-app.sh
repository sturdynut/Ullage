#!/usr/bin/env bash
# Build a universal drag-to-Applications DMG. No installation or launch.
# ULLAGE_VERSION=X.Y.Z scripts/package-app.sh [out-dir]
# Set CODE_SIGN_IDENTITY and NOTARY_PROFILE for a signed, notarized release.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"
export ULLAGE_VERSION="${ULLAGE_VERSION:-0.0.0}"
ULLAGE_VERSION="${ULLAGE_VERSION#v}"
if [[ ! "$ULLAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'ULLAGE_VERSION must be X.Y.Z (optionally prefixed with v)' >&2
  exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" && "${CODE_SIGN_IDENTITY:--}" == "-" ]]; then
  echo 'Notarization requires CODE_SIGN_IDENTITY (a Developer ID Application certificate)' >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
SWIFT_BUILD_FLAGS="${SWIFT_BUILD_FLAGS:-} --arch arm64 --arch x86_64" scripts/bundle-app.sh "$STAGE/image"
APP="$STAGE/image/Ullage.app"

# Staple the app before packaging so it can also be checked offline after copying.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/Ullage.zip"
  xcrun notarytool submit "$STAGE/Ullage.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

ln -s /Applications "$STAGE/image/Applications"
NAME="Ullage-${ULLAGE_VERSION}-universal.dmg"
hdiutil create -volname Ullage -srcfolder "$STAGE/image" -format UDZO "$STAGE/$NAME"
if [[ "${CODE_SIGN_IDENTITY:--}" != "-" ]]; then
  codesign --timestamp --sign "$CODE_SIGN_IDENTITY" "$STAGE/$NAME"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$STAGE/$NAME" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE/$NAME"
  xcrun stapler validate "$STAGE/$NAME"
  spctl --assess --type open --context context:primary-signature --verbose "$STAGE/$NAME"
fi

scripts/verify-dmg.sh "$STAGE/$NAME" "$ULLAGE_VERSION"
mkdir -p "$OUT_DIR"
cp "$STAGE/$NAME" "$OUT_DIR/$NAME"
(cd "$OUT_DIR" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "built $OUT_DIR/$NAME"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo 'Local build: not notarized; downloaded copies may be blocked by Gatekeeper.'
fi
