#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT="${PROJECT:-$SCRIPT_DIR/Emyn.xcodeproj}"
SCHEME="${SCHEME:-Emyn}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"
APP_NAME="${APP_NAME:-Emyn}"

RELEASE_ROOT="${RELEASE_ROOT:-$SCRIPT_DIR/.release}"
BUILD_DIR="${BUILD_DIR:-$RELEASE_ROOT/build}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_DIR/DerivedData}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$RELEASE_ROOT/archive}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ARCHIVE_DIR/$APP_NAME.xcarchive}"
OUTPUT_DIR="${OUTPUT_DIR:-$RELEASE_ROOT/dist}"
OUTPUT_APP="$OUTPUT_DIR/$APP_NAME.app"
OUTPUT_DSYM="$OUTPUT_DIR/$APP_NAME.app.dSYM"
OUTPUT_ZIP="$OUTPUT_DIR/$APP_NAME.zip"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$SCRIPT_DIR/ExportOptions.developer-id.plist}"
NOTARY_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-my-signer}"

BUILD_ONLY=false
CLEAN=true
BUILD_XCFRAMEWORK=true
ENSURE_TRANSCRIBE_CPP=true
SIGNING_MODE="${SIGNING_MODE:-developer-id}"

usage() {
  cat <<EOF
Usage:
  ./release.sh
  ./release.sh --build-only
  ./release.sh --development

Options:
  --build-only        Build and copy the release app, but do not sign/notarize.
  --developer-id      Archive/export with Xcode automatic Developer ID signing,
                      then notarize and staple. This is the default.
  --development       Sign with Apple Development profiles and skip notarization.
                      Use this for a local /Applications install on registered Macs.
  --no-clean          Reuse the existing release DerivedData.
  --skip-xcframework  Do not rebuild platform-macos' UniFFI XCFramework first.
  --skip-transcribe-cpp
                      Do not generate the local TranscribeCpp XCFramework first.
  -h, --help          Show this help.

Environment overrides:
  PROJECT                         Defaults to Emyn.xcodeproj
  SCHEME                          Defaults to Emyn
  CONFIGURATION                   Defaults to Release
  DESTINATION                     Defaults to generic/platform=macOS
  RELEASE_ROOT                    Defaults to .release
  ARCHIVE_PATH                    Defaults to .release/archive/Emyn.xcarchive
  OUTPUT_DIR                      Defaults to .release/dist
  EXPORT_OPTIONS_PLIST            Defaults to ExportOptions.developer-id.plist
  CODESIGN_IDENTITY               Passed through to sign.sh
  DEVELOPMENT_CODESIGN_IDENTITY   Defaults to Apple Development: Benedikt Terhechte (GZE4QKBCG9)
  DEVELOPMENT_TEAM                Defaults to 76VT9VZ6GK
  NOTARY_KEYCHAIN_PROFILE         Passed through to sign.sh
  APP_PROVISIONING_PROFILE        Passed through to sign.sh
  SYSTEM_EXTENSION_PROVISIONING_PROFILE
                                  Passed through to sign.sh
  TRANSCRIBE_CPP_VERSION          Release tag for TranscribeCpp, defaults to latest
  UPDATE_TRANSCRIBE_CPP           Set true to refresh even if the XCFramework exists
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    --developer-id)
      SIGNING_MODE="developer-id"
      shift
      ;;
    --development)
      SIGNING_MODE="development"
      shift
      ;;
    --no-clean)
      CLEAN=false
      shift
      ;;
    --skip-xcframework)
      BUILD_XCFRAMEWORK=false
      shift
      ;;
    --skip-transcribe-cpp)
      ENSURE_TRANSCRIBE_CPP=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command xcodebuild
require_command ditto
require_command lipo

verify_app_slices() {
  echo "==> Verifying built slices"
  lipo -info "$OUTPUT_APP/Contents/MacOS/$APP_NAME"
  find "$OUTPUT_APP/Contents/Library/SystemExtensions" \
    -maxdepth 1 \
    -type d \
    -name "*.systemextension" \
    -print \
    | while IFS= read -r system_extension; do
        executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$system_extension/Contents/Info.plist")"
        lipo -info "$system_extension/Contents/MacOS/$executable_name"
      done
}

clear_app_extended_attributes() {
  echo "==> Removing extended attributes from $OUTPUT_APP"
  xattr -cr "$OUTPUT_APP" 2>/dev/null || true
}

build_unsigned_app() {
  echo "==> Building $APP_NAME ($CONFIGURATION)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build

  BUILT_PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"
  BUILT_APP="$BUILT_PRODUCTS_DIR/$APP_NAME.app"
  BUILT_DSYM="$BUILT_PRODUCTS_DIR/$APP_NAME.app.dSYM"

  if [[ ! -d "$BUILT_APP" ]]; then
    echo "Built app not found: $BUILT_APP" >&2
    exit 1
  fi

  echo "==> Copying release app to $OUTPUT_APP"
  rm -rf "$OUTPUT_APP" "$OUTPUT_DSYM" "$OUTPUT_ZIP"
  ditto "$BUILT_APP" "$OUTPUT_APP"

  if [[ -d "$BUILT_DSYM" ]]; then
    ditto "$BUILT_DSYM" "$OUTPUT_DSYM"
  fi

  clear_app_extended_attributes
  verify_app_slices
}

archive_and_export_developer_id_app() {
  require_command xcrun

  if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
    echo "Export options plist not found: $EXPORT_OPTIONS_PLIST" >&2
    exit 1
  fi

  echo "==> Archiving $APP_NAME with Xcode automatic signing"
  rm -rf "$ARCHIVE_PATH" "$OUTPUT_APP" "$OUTPUT_DSYM" "$OUTPUT_ZIP"
  mkdir -p "$ARCHIVE_DIR" "$OUTPUT_DIR"

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -allowProvisioningUpdates \
    archive

  echo "==> Exporting Developer ID app with Xcode automatic signing"
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates

  if [[ ! -d "$OUTPUT_APP" ]]; then
    exported_app="$(find "$OUTPUT_DIR" -maxdepth 1 -type d -name "*.app" -print | head -n 1)"
    if [[ -n "$exported_app" ]]; then
      OUTPUT_APP="$exported_app"
    else
      echo "Exported app not found in: $OUTPUT_DIR" >&2
      exit 1
    fi
  fi

  rm -rf "$OUTPUT_DSYM"
  if [[ -d "$ARCHIVE_PATH/dSYMs/$APP_NAME.app.dSYM" ]]; then
    ditto "$ARCHIVE_PATH/dSYMs/$APP_NAME.app.dSYM" "$OUTPUT_DSYM"
  fi

  clear_app_extended_attributes
  verify_app_slices
}

notarize_and_staple_app() {
  require_command xcrun

  echo "==> Verifying exported Developer ID signature"
  codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

  echo "==> Creating notarization archive at $OUTPUT_ZIP"
  rm -f "$OUTPUT_ZIP"
  ditto -c -k --keepParent "$OUTPUT_APP" "$OUTPUT_ZIP"

  echo "==> Submitting for notarization using profile '$NOTARY_PROFILE'"
  xcrun notarytool submit "$OUTPUT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling ticket"
  xcrun stapler staple "$OUTPUT_APP"

  echo "==> Final Gatekeeper verification"
  spctl --assess --type execute --verbose=4 "$OUTPUT_APP"
  codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
}

cd "$SCRIPT_DIR"

if [[ "$BUILD_XCFRAMEWORK" == true ]]; then
  echo "==> Building platform-macos XCFramework"
  "$SCRIPT_DIR/platform-macos/scripts/build-xcframework.sh"
fi

if [[ "$ENSURE_TRANSCRIBE_CPP" == true ]]; then
  TRANSCRIBE_CPP_XCFRAMEWORK="$SCRIPT_DIR/transcribe-cpp-swift/TranscribeCpp.xcframework"
  if [[ ! -d "$TRANSCRIBE_CPP_XCFRAMEWORK" || "${UPDATE_TRANSCRIBE_CPP:-false}" == true ]]; then
    "$SCRIPT_DIR/transcribe-cpp-swift/scripts/update-xcframework.sh" "${TRANSCRIBE_CPP_VERSION:-latest}"
  fi
fi

if [[ "$CLEAN" == true ]]; then
  echo "==> Cleaning release build outputs"
  rm -rf "$DERIVED_DATA_PATH" "$ARCHIVE_PATH" "$OUTPUT_APP" "$OUTPUT_DSYM" "$OUTPUT_ZIP"
fi

mkdir -p "$OUTPUT_DIR"

if [[ "$BUILD_ONLY" == true ]]; then
  build_unsigned_app
  echo "Release app built: $OUTPUT_APP"
  exit 0
fi

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  archive_and_export_developer_id_app
  if [[ "${NOTARIZE:-true}" == true ]]; then
    notarize_and_staple_app
  else
    echo "==> Skipping notarization"
    codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
  fi
elif [[ "$SIGNING_MODE" == "development" ]]; then
  build_unsigned_app
  echo "==> Development signing selected; notarization will be skipped"
  NOTARIZE=false \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-76VT9VZ6GK}" \
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-${DEVELOPMENT_CODESIGN_IDENTITY:-Apple Development: Benedikt Terhechte (GZE4QKBCG9)}}" \
    "$SCRIPT_DIR/sign.sh" "$OUTPUT_APP"
else
  echo "Unknown signing mode: $SIGNING_MODE" >&2
  exit 1
fi

echo "Release complete:"
echo "  App:  $OUTPUT_APP"
if [[ -f "$OUTPUT_ZIP" ]]; then
  echo "  Zip:  $OUTPUT_ZIP"
fi
if [[ -d "$OUTPUT_DSYM" ]]; then
  echo "  dSYM: $OUTPUT_DSYM"
fi
