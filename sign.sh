#!/bin/bash
set -euo pipefail

# Codesign and notarize the built Emyn app bundle.
# Usage: ./sign.sh [path/to/Emyn.app]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-./Emyn.app}"
APP="${APP%/}"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Benedikt Terhechte (76VT9VZ6GK)}"
TEAM_IDENTIFIER="${DEVELOPMENT_TEAM:-76VT9VZ6GK}"
APP_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-$SCRIPT_DIR/Emyn/Emyn.entitlements}"
SYSTEM_EXTENSION_ENTITLEMENTS="${SYSTEM_EXTENSION_ENTITLEMENTS:-$SCRIPT_DIR/EmynVirtualCameraExtension/EmynVirtualCameraExtension.entitlements}"
SYSTEM_EXTENSION_IDENTIFIER="${SYSTEM_EXTENSION_IDENTIFIER:-com.stylemac.Emyn.VirtualCameraExtension}"
SYSTEM_EXTENSION="${SYSTEM_EXTENSION:-}"
NOTARY_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-my-signer}"
NOTARIZE="${NOTARIZE:-true}"
AUTO_PROVISIONING_PROFILES="${AUTO_PROVISIONING_PROFILES:-true}"
PROVISIONING_PROFILE_SEARCH_DIRS="${PROVISIONING_PROFILE_SEARCH_DIRS:-$HOME/Library/MobileDevice/Provisioning Profiles:$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"

# Optional provisioning profiles. If left unset, matching profiles are resolved
# from Xcode's local provisioning profile cache.
APP_PROVISIONING_PROFILE="${APP_PROVISIONING_PROFILE:-}"
SYSTEM_EXTENSION_PROVISIONING_PROFILE="${SYSTEM_EXTENSION_PROVISIONING_PROFILE:-}"

require_file() {
  local path="$1"
  local label="$2"

  if [[ ! -f "$path" ]]; then
    echo "$label not found: $path" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

bundle_identifier() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || true
}

decode_profile() {
  security cms -D -i "$1" > "$2" 2>/dev/null
}

identity_hash() {
  security find-identity -v -p codesigning \
    | awk -v identity="$1" 'index($0, "\"" identity "\"") { print toupper($2); exit }'
}

profile_app_identifier() {
  local plist="$1"
  local app_identifier

  app_identifier="$(plist_value "$plist" ":Entitlements:com.apple.application-identifier")"
  if [[ -z "$app_identifier" ]]; then
    app_identifier="$(plist_value "$plist" ":Entitlements:application-identifier")"
  fi
  printf '%s\n' "$app_identifier"
}

profile_contains_osx_platform() {
  /usr/libexec/PlistBuddy -c "Print :Platform" "$1" 2>/dev/null | grep -q "OSX"
}

profile_contains_identity() {
  local plist="$1"
  local expected_hash="$2"
  local cert_xml cert_der index fingerprint found

  cert_xml="$(mktemp)"
  cert_der="$(mktemp)"
  index=0
  found=false

  while /usr/libexec/PlistBuddy -x -c "Print :DeveloperCertificates:$index" "$plist" > "$cert_xml" 2>/dev/null; do
    if awk '
      /<data>/ { in_data = 1; next }
      /<\/data>/ { in_data = 0 }
      in_data { gsub(/[[:space:]]/, ""); printf "%s", $0 }
    ' "$cert_xml" | base64 -D > "$cert_der" 2>/dev/null; then
      fingerprint="$(
        openssl x509 -inform DER -in "$cert_der" -noout -fingerprint -sha1 2>/dev/null \
          | sed -E 's/^[^=]+=//; s/://g' \
          | tr '[:lower:]' '[:upper:]'
      )"
      if [[ "$fingerprint" == "$expected_hash" ]]; then
        found=true
        break
      fi
    fi
    index=$((index + 1))
  done

  rm -f "$cert_xml" "$cert_der"
  [[ "$found" == true ]]
}

validate_profile() {
  local profile="$1"
  local bundle_id="$2"
  local label="$3"
  local signing_identity_hash="$4"
  local plist profile_team app_identifier expected_identifier profile_name

  plist="$(mktemp)"
  if ! decode_profile "$profile" "$plist"; then
    rm -f "$plist"
    echo "$label provisioning profile could not be decoded: $profile" >&2
    exit 1
  fi

  profile_name="$(plist_value "$plist" ":Name")"
  profile_team="$(plist_value "$plist" ":TeamIdentifier:0")"
  app_identifier="$(profile_app_identifier "$plist")"
  expected_identifier="$TEAM_IDENTIFIER.$bundle_id"

  if [[ "$profile_team" != "$TEAM_IDENTIFIER" ]]; then
    rm -f "$plist"
    echo "$label provisioning profile has team '$profile_team', expected '$TEAM_IDENTIFIER': $profile" >&2
    exit 1
  fi

  if [[ "$app_identifier" != "$expected_identifier" ]]; then
    rm -f "$plist"
    echo "$label provisioning profile has app identifier '$app_identifier', expected '$expected_identifier': $profile" >&2
    exit 1
  fi

  if ! profile_contains_osx_platform "$plist"; then
    rm -f "$plist"
    echo "$label provisioning profile is not a macOS profile: $profile" >&2
    exit 1
  fi

  if ! profile_contains_identity "$plist" "$signing_identity_hash"; then
    rm -f "$plist"
    echo "$label provisioning profile does not contain signing identity '$IDENTITY': $profile" >&2
    exit 1
  fi

  rm -f "$plist"
  printf '%s\n' "$profile_name"
}

find_matching_profile() {
  local bundle_id="$1"
  local label="$2"
  local signing_identity_hash="$3"
  local profile_dirs=()
  local profile plist profile_team app_identifier expected_identifier

  IFS=":" read -r -a profile_dirs <<< "$PROVISIONING_PROFILE_SEARCH_DIRS"
  expected_identifier="$TEAM_IDENTIFIER.$bundle_id"

  while IFS= read -r profile; do
    plist="$(mktemp)"
    if decode_profile "$profile" "$plist"; then
      profile_team="$(plist_value "$plist" ":TeamIdentifier:0")"
      app_identifier="$(profile_app_identifier "$plist")"

      if [[ "$profile_team" == "$TEAM_IDENTIFIER" ]] \
        && [[ "$app_identifier" == "$expected_identifier" ]] \
        && profile_contains_osx_platform "$plist" \
        && profile_contains_identity "$plist" "$signing_identity_hash"; then
        rm -f "$plist"
        printf '%s\n' "$profile"
        return 0
      fi
    fi
    rm -f "$plist"
  done < <(
    for profile_dir in "${profile_dirs[@]}"; do
      if [[ -d "$profile_dir" ]]; then
        find "$profile_dir" -type f \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print
      fi
    done
  )

  echo "No matching $label provisioning profile found for $expected_identifier and identity '$IDENTITY'." >&2
  echo "Install or download the matching profile, or set $(profile_env_name "$label") explicitly." >&2
  return 1
}

profile_env_name() {
  case "$1" in
    app)
      echo "APP_PROVISIONING_PROFILE"
      ;;
    system_extension)
      echo "SYSTEM_EXTENSION_PROVISIONING_PROFILE"
      ;;
    *)
      echo "PROVISIONING_PROFILE"
      ;;
  esac
}

resolve_profile() {
  local provided_profile="$1"
  local bundle_id="$2"
  local label="$3"
  local signing_identity_hash="$4"
  local resolved_profile profile_name

  if [[ -n "$provided_profile" ]]; then
    require_file "$provided_profile" "$label provisioning profile"
    if ! profile_name="$(validate_profile "$provided_profile" "$bundle_id" "$label" "$signing_identity_hash")"; then
      exit 1
    fi
    echo "==> Using $label provisioning profile: $profile_name" >&2
    printf '%s\n' "$provided_profile"
    return 0
  fi

  if [[ "$AUTO_PROVISIONING_PROFILES" != true ]]; then
    return 0
  fi

  if ! resolved_profile="$(find_matching_profile "$bundle_id" "$label" "$signing_identity_hash")"; then
    exit 1
  fi

  if [[ -z "$resolved_profile" ]]; then
    echo "Resolved empty $label provisioning profile path." >&2
    exit 1
  fi

  if ! profile_name="$(validate_profile "$resolved_profile" "$bundle_id" "$label" "$signing_identity_hash")"; then
    exit 1
  fi
  echo "==> Using $label provisioning profile: $profile_name" >&2
  printf '%s\n' "$resolved_profile"
}

if [[ ! -d "$APP" ]]; then
  echo "App bundle not found: $APP" >&2
  exit 1
fi

require_command codesign
require_command security
require_command openssl
require_command ditto

if [[ "$NOTARIZE" == true ]]; then
  require_command xcrun
fi

APP_DIR="$(cd "$(dirname "$APP")" && pwd)"
APP_BASENAME="$(basename "$APP")"
APP="$APP_DIR/$APP_BASENAME"

require_file "$APP_ENTITLEMENTS" "App entitlements file"
require_file "$SYSTEM_EXTENSION_ENTITLEMENTS" "System extension entitlements file"

APP_IDENTIFIER="$(bundle_identifier "$APP")"
SIGNING_IDENTITY_HASH="$(identity_hash "$IDENTITY")"

if [[ -z "$SIGNING_IDENTITY_HASH" ]]; then
  echo "Codesigning identity not found: $IDENTITY" >&2
  exit 1
fi

if [[ -z "$SYSTEM_EXTENSION" ]]; then
  SYSTEM_EXTENSION="$(
    find "$APP/Contents/Library/SystemExtensions" \
      -maxdepth 1 \
      -type d \
      -name "*.systemextension" \
      -print 2>/dev/null \
      | while IFS= read -r candidate; do
          if [[ "$(bundle_identifier "$candidate")" == "$SYSTEM_EXTENSION_IDENTIFIER" ]]; then
            printf '%s\n' "$candidate"
            break
          fi
        done
  )"
fi

if [[ -z "$SYSTEM_EXTENSION" || ! -d "$SYSTEM_EXTENSION" ]]; then
  echo "System extension not found in app bundle: $SYSTEM_EXTENSION_IDENTIFIER" >&2
  exit 1
fi

if [[ "$(bundle_identifier "$SYSTEM_EXTENSION")" != "$SYSTEM_EXTENSION_IDENTIFIER" ]]; then
  echo "System extension identifier mismatch in: $SYSTEM_EXTENSION" >&2
  echo "Expected: $SYSTEM_EXTENSION_IDENTIFIER" >&2
  echo "Actual:   $(bundle_identifier "$SYSTEM_EXTENSION")" >&2
  exit 1
fi

APP_PROVISIONING_PROFILE="$(
  resolve_profile "$APP_PROVISIONING_PROFILE" "$APP_IDENTIFIER" "app" "$SIGNING_IDENTITY_HASH"
)"
SYSTEM_EXTENSION_PROVISIONING_PROFILE="$(
  resolve_profile "$SYSTEM_EXTENSION_PROVISIONING_PROFILE" "$SYSTEM_EXTENSION_IDENTIFIER" "system_extension" "$SIGNING_IDENTITY_HASH"
)"

echo "==> Removing extended attributes"
xattr -cr "$APP" 2>/dev/null || true

rm -f "$APP/Contents/embedded.provisionprofile"
rm -f "$SYSTEM_EXTENSION/Contents/embedded.provisionprofile"

if [[ -n "$SYSTEM_EXTENSION_PROVISIONING_PROFILE" ]]; then
  echo "==> Embedding system extension provisioning profile"
  cp "$SYSTEM_EXTENSION_PROVISIONING_PROFILE" "$SYSTEM_EXTENSION/Contents/embedded.provisionprofile"
fi

if [[ -n "$APP_PROVISIONING_PROFILE" ]]; then
  echo "==> Embedding app provisioning profile"
  cp "$APP_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

echo "==> Codesigning system extension with hardened runtime"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  --entitlements "$SYSTEM_EXTENSION_ENTITLEMENTS" \
  "$SYSTEM_EXTENSION"

echo "==> Codesigning app with hardened runtime"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "==> Verifying signatures"
codesign --verify --strict --verbose=2 "$SYSTEM_EXTENSION"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$NOTARIZE" == true ]]; then
  ZIP_PATH="${ZIP_PATH:-$APP_DIR/$(basename "${APP%.app}").zip}"
  echo "==> Creating notarization archive at $ZIP_PATH"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP" "$ZIP_PATH"

  echo "==> Submitting for notarization using profile '$NOTARY_PROFILE'"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling ticket"
  xcrun stapler staple "$APP"

  echo "==> Final Gatekeeper verification"
  spctl --assess --type execute --verbose=4 "$APP"
else
  echo "==> Skipping notarization"
fi

echo "==> Final signature verification"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Done. Signed app: $APP"
