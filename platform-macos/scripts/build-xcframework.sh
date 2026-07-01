#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_PACKAGE="platform-macos"
LIB_NAME="platform_macos"
# Must match the FFI module name uniffi derives for the generated Swift
# wrapper (its `import` statement), i.e. the crate's uniffi namespace + "FFI".
FFI_MODULE_NAME="${LIB_NAME}FFI"
KIT_MODULE_NAME="PlatformMacOSKit"
PACKAGE_DIR="$ROOT/swift/$KIT_MODULE_NAME"
BUILD_DIR="$ROOT/target/$CRATE_PACKAGE-xcframework"
RELEASE_DIR="release"
MACOS_DEPLOYMENT_TARGET="${PLATFORM_MACOS_DEPLOYMENT_TARGET:-13.0}"

MACOS_TARGETS=(
  "aarch64-apple-darwin"
  "x86_64-apple-darwin"
)

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to create the xcframework" >&2
  exit 1
fi

if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is required to install and resolve Rust macOS targets" >&2
  exit 1
fi

cd "$ROOT"

CARGO_BIN="$(rustup which cargo)"
RUSTC_BIN="$(rustup which rustc)"

run_cargo() {
  RUSTC="$RUSTC_BIN" MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    "$CARGO_BIN" "$@"
}

fix_static_library_modulemap() {
  local modulemap="$1/module.modulemap"
  if [[ ! -f "$modulemap" ]]; then
    echo "Missing generated module map: $modulemap" >&2
    exit 1
  fi
  # The generated modulemap assumes it lives inside a real .framework bundle;
  # we're linking a plain static library, so drop the "framework" qualifier.
  perl -0pi -e "s/\\Aframework module \\Q$FFI_MODULE_NAME\\E /module $FFI_MODULE_NAME /" "$modulemap"
}

MACOS_LIBS=()
for macos_target in "${MACOS_TARGETS[@]}"; do
  echo "Installing Rust target: $macos_target"
  rustup target add "$macos_target"

  echo "Building Rust static library ($macos_target, release)"
  run_cargo build -p "$CRATE_PACKAGE" --release --target "$macos_target"
  MACOS_LIBS+=("$ROOT/target/$macos_target/$RELEASE_DIR/lib$LIB_NAME.a")
done

MACOS_LIB="${MACOS_LIBS[0]}"

GEN_SWIFT_DIR="$BUILD_DIR/generated-swift"
HEADERS_DIR="$BUILD_DIR/headers"
rm -rf "$BUILD_DIR"
mkdir -p "$GEN_SWIFT_DIR" "$HEADERS_DIR"

echo "Generating UniFFI Swift bindings"
run_cargo run -p "$CRATE_PACKAGE" --features uniffi-bindgen --bin uniffi-bindgen-swift -- \
  "$MACOS_LIB" "$GEN_SWIFT_DIR" --swift-sources
run_cargo run -p "$CRATE_PACKAGE" --features uniffi-bindgen --bin uniffi-bindgen-swift -- \
  "$MACOS_LIB" "$HEADERS_DIR" --headers
run_cargo run -p "$CRATE_PACKAGE" --features uniffi-bindgen --bin uniffi-bindgen-swift -- \
  "$MACOS_LIB" "$HEADERS_DIR" --xcframework --modulemap \
  --module-name "$FFI_MODULE_NAME" --modulemap-filename module.modulemap
fix_static_library_modulemap "$HEADERS_DIR"

echo "Creating Swift package layout"
mkdir -p "$PACKAGE_DIR/Sources/$KIT_MODULE_NAME"
while IFS= read -r -d '' swift_source; do
  rm -f "$PACKAGE_DIR/Sources/$KIT_MODULE_NAME/$(basename "$swift_source")"
  cp "$swift_source" "$PACKAGE_DIR/Sources/$KIT_MODULE_NAME/"
done < <(find "$GEN_SWIFT_DIR" -maxdepth 1 -type f -name '*.swift' -print0)

echo "Creating xcframework"
rm -rf "$PACKAGE_DIR/$FFI_MODULE_NAME.xcframework"
UNIVERSAL_LIB_DIR="$BUILD_DIR/macos-universal"
UNIVERSAL_LIB="$UNIVERSAL_LIB_DIR/lib$LIB_NAME.a"
mkdir -p "$UNIVERSAL_LIB_DIR"
lipo -create "${MACOS_LIBS[@]}" -output "$UNIVERSAL_LIB"

xcodebuild -create-xcframework \
  -library "$UNIVERSAL_LIB" -headers "$HEADERS_DIR" \
  -output "$PACKAGE_DIR/$FFI_MODULE_NAME.xcframework"

echo "Built $PACKAGE_DIR/$FFI_MODULE_NAME.xcframework"
echo "Generated Swift sources in $PACKAGE_DIR/Sources/$KIT_MODULE_NAME"
