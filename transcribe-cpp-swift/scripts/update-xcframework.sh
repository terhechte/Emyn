#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO="${TRANSCRIBE_CPP_REPO:-handy-computer/transcribe.cpp}"
ASSET_NAME="${TRANSCRIBE_CPP_ASSET_NAME:-TranscribeCpp.xcframework.zip}"
OUTPUT="${TRANSCRIBE_CPP_XCFRAMEWORK_PATH:-$PACKAGE_DIR/TranscribeCpp.xcframework}"
VERSION="${1:-${TRANSCRIBE_CPP_VERSION:-latest}}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

run_curl() {
  local args=(-fsSL)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl "${args[@]}" "$@"
}

latest_release_tag() {
  local api_url="https://api.github.com/repos/$REPO/releases/latest"
  run_curl "$api_url" | /usr/bin/plutil -extract tag_name raw -o - -
}

repair_macos_framework() {
  local framework="$1"
  local binary_name="$2"

  [[ -d "$framework/Versions/A" ]] || return 0

  echo "==> Repairing macOS framework symlinks"
  rm -rf "$framework/Versions/Current"
  ln -s A "$framework/Versions/Current"

  local item
  for item in "$binary_name" Headers Modules Resources; do
    if [[ -e "$framework/Versions/A/$item" || -L "$framework/Versions/A/$item" ]]; then
      rm -rf "$framework/$item"
      ln -s "Versions/Current/$item" "$framework/$item"
    fi
  done
}

case "$OUTPUT" in
  *.xcframework) ;;
  *)
    echo "Refusing to overwrite non-XCFramework path: $OUTPUT" >&2
    exit 1
    ;;
esac

require_command curl
require_command ditto
require_command find

if [[ -n "${TRANSCRIBE_CPP_URL:-}" ]]; then
  TAG="${VERSION}"
  DOWNLOAD_URL="$TRANSCRIBE_CPP_URL"
else
  if [[ "$VERSION" == "latest" ]]; then
    TAG="$(latest_release_tag)"
  else
    TAG="$VERSION"
  fi
  DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ASSET_NAME"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="$TMP_DIR/$ASSET_NAME"
UNPACK_DIR="$TMP_DIR/unpacked"

echo "==> Downloading TranscribeCpp $TAG"
echo "    $DOWNLOAD_URL"
run_curl -L "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"

mkdir -p "$UNPACK_DIR"
ditto -x -k "$ARCHIVE_PATH" "$UNPACK_DIR"

XCFRAMEWORK="$(find "$UNPACK_DIR" -name "TranscribeCpp.xcframework" -type d -print -quit)"
if [[ -z "$XCFRAMEWORK" ]]; then
  echo "Downloaded archive did not contain TranscribeCpp.xcframework" >&2
  exit 1
fi

echo "==> Installing $OUTPUT"
rm -rf "$OUTPUT"
ditto "$XCFRAMEWORK" "$OUTPUT"
find "$OUTPUT" -name ".DS_Store" -delete
xattr -cr "$OUTPUT" 2>/dev/null || true

MACOS_FRAMEWORK="$OUTPUT/macos-arm64_x86_64/CTranscribe.framework"
if [[ ! -d "$MACOS_FRAMEWORK" ]]; then
  echo "Expected macOS framework not found: $MACOS_FRAMEWORK" >&2
  exit 1
fi

repair_macos_framework "$MACOS_FRAMEWORK" CTranscribe

if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing repaired macOS framework"
  codesign --force --sign - "$MACOS_FRAMEWORK"
  codesign --verify --strict --verbose=2 "$MACOS_FRAMEWORK"
fi

echo "==> Done"
echo "Generated: $OUTPUT"
