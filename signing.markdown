# Emyn Signing Profiles

This project has two separately signed bundles:

| Bundle | Identifier | Entitlements that matter for profiles |
| --- | --- | --- |
| Host app | `com.stylemac.Emyn` | `com.apple.developer.system-extension.install`, `com.apple.security.application-groups = group.com.stylemac.Emyn` |
| Virtual camera system extension | `com.stylemac.Emyn.VirtualCameraExtension` | `com.apple.security.application-groups = group.com.stylemac.Emyn`, `com.apple.security.device.camera` |

The app and the embedded system extension both need provisioning profiles when signed with restricted entitlements. A notarized Developer ID signature alone is not enough: macOS can accept the signature with `spctl` but still refuse to launch the app through `amfid` with `No matching profile found` if the required embedded profiles are missing or do not match the signing certificate.

## Signing Modes

| Use case | Script | Signing identity | Profile type | Notarized |
| --- | --- | --- | --- | --- |
| Local install on registered Macs | `./release.sh --development` | `Apple Development` | `Mac App Development` profiles | No |
| Outside-Mac-App-Store distribution | `./release.sh` | `Developer ID Application` | Xcode-managed direct distribution profiles | Yes |

For local testing, `./release.sh --development` can use Xcode-managed Mac development profiles. For a real distributable release, use Xcode archive/export with automatic signing. Xcode can create the required direct distribution profiles when the App IDs and capabilities are valid for your team.

## Xcode Archive Flow

The project is configured with automatic signing for both targets. In Xcode:

1. Select the `Emyn` scheme.
2. Choose `Product > Archive`.
3. In Organizer, choose `Distribute App`.
4. Choose the Developer ID/direct distribution option.
5. Keep automatic signing enabled.
6. Let Xcode create or update the signing profiles.
7. Export the app.

This is the point where Xcode can create profiles such as:

- `Mac Team Direct Provisioning Profile: com.stylemac.Emyn`
- `Mac Team Direct Provisioning Profile: com.stylemac.Emyn.VirtualCameraExtension`

The command-line equivalent is the default release script:

```bash
./release.sh
```

Internally, it runs `xcodebuild archive`, then `xcodebuild -exportArchive` with `-allowProvisioningUpdates` and [ExportOptions.developer-id.plist](ExportOptions.developer-id.plist). After Xcode exports the Developer ID-signed app, the script notarizes and staples it.

To test only the Xcode archive/export path without submitting to notarization:

```bash
NOTARIZE=false ./release.sh --skip-xcframework --no-clean
```

## Profiles Xcode Must Create

Xcode needs two macOS direct distribution profiles:

1. Host app profile
   - Distribution type: Developer ID/direct distribution
   - App ID: `com.stylemac.Emyn`
   - Certificate: `Developer ID Application: Benedikt Terhechte (76VT9VZ6GK)`
   - Capabilities:
     - System Extension
     - App Groups, with `group.com.stylemac.Emyn`

2. Virtual camera extension profile
   - Distribution type: Developer ID/direct distribution
   - App ID: `com.stylemac.Emyn.VirtualCameraExtension`
   - Certificate: `Developer ID Application: Benedikt Terhechte (76VT9VZ6GK)`
   - Capabilities:
     - App Groups, with `group.com.stylemac.Emyn`

Both profiles must contain the same Developer ID Application certificate used for export. If the profile was generated for an Apple Development certificate, it will not satisfy a Developer ID signature.

## Create The App IDs

In Apple Developer, open Certificates, Identifiers & Profiles.

1. Go to `Identifiers`.
2. Create or edit an explicit App ID for `com.stylemac.Emyn`.
3. Enable `System Extension`.
4. Enable `App Groups`, then assign `group.com.stylemac.Emyn`.
5. Save the App ID.
6. Create or edit an explicit App ID for `com.stylemac.Emyn.VirtualCameraExtension`.
7. Enable `App Groups`, then assign `group.com.stylemac.Emyn`.
8. Save the App ID.

If you change capabilities on an App ID, regenerate any provisioning profiles that use it. Apple marks affected profiles invalid when App ID capabilities change.

## Create The Developer ID Certificate

You already have the expected identity installed if this command prints it:

```bash
security find-identity -v -p codesigning | rg "Developer ID Application: Benedikt Terhechte \\(76VT9VZ6GK\\)"
```

If it is missing, create a `Developer ID Application` certificate in Apple Developer and install the certificate plus its private key in your login keychain.

## Manual Fallback: Create The Profiles Yourself

Use this only if Xcode automatic signing cannot create the direct distribution profiles. Repeat this once for the host app and once for the virtual camera extension:

1. Go to `Profiles`.
2. Click `+`.
3. Under `Distribution`, choose the Developer ID/direct distribution profile type.
4. Select the matching App ID:
   - `com.stylemac.Emyn` for the host app profile.
   - `com.stylemac.Emyn.VirtualCameraExtension` for the extension profile.
5. Select the `Developer ID Application: Benedikt Terhechte (76VT9VZ6GK)` certificate.
6. Name the profiles clearly, for example:
   - `Emyn Direct App`
   - `Emyn Direct Virtual Camera Extension`
7. Generate and download each `.provisionprofile`.
8. Install them by opening the downloaded files, or copy them into one of these directories:

```bash
~/Library/MobileDevice/Provisioning Profiles
~/Library/Developer/Xcode/UserData/Provisioning Profiles
```

The manual `sign.sh` fallback searches both directories automatically. You can also pass exact paths:

```bash
./release.sh --build-only
APP_PROVISIONING_PROFILE=/path/to/Emyn_App_Developer_ID.provisionprofile \
SYSTEM_EXTENSION_PROVISIONING_PROFILE=/path/to/Emyn_Extension_Developer_ID.provisionprofile \
./sign.sh /Users/terhechte/Developer/Swift/Emyn/.release/dist/Emyn.app
```

## Validate Profiles Locally

To inspect a downloaded profile:

```bash
security cms -D -i /path/to/profile.provisionprofile | plutil -p -
```

Check these fields:

- `TeamIdentifier` contains `76VT9VZ6GK`.
- `Platform` contains `OSX`.
- `Entitlements.com.apple.application-identifier` matches:
  - `76VT9VZ6GK.com.stylemac.Emyn`
  - `76VT9VZ6GK.com.stylemac.Emyn.VirtualCameraExtension`
- The host app profile contains `com.apple.developer.system-extension.install = true`.
- Both profiles contain `group.com.stylemac.Emyn` in `com.apple.security.application-groups`.

The manual fallback also validates that each profile contains the exact signing certificate being used. If it cannot find a matching Developer ID/direct distribution profile, it fails before signing.

## Build And Install

For a local registered-Mac build:

```bash
./release.sh --development
rm -rf /Applications/Emyn.app
ditto /Users/terhechte/Developer/Swift/Emyn/.release/dist/Emyn.app /Applications/Emyn.app
```

For a notarized Developer ID release through Xcode automatic archive/export:

```bash
./release.sh
rm -rf /Applications/Emyn.app
ditto /Users/terhechte/Developer/Swift/Emyn/.release/dist/Emyn.app /Applications/Emyn.app
```

Prefer `ditto` over `cp -R` for app bundles. Removing the old bundle first avoids accidentally merging a new app into an older copy.

For the virtual camera extension, these bundle-layout details matter:

- The embedded `.systemextension` directory name must match the extension bundle identifier:
  `com.stylemac.Emyn.VirtualCameraExtension.systemextension`.
- `CMIOExtensionMachServiceName` must be prefixed with an App Group in the extension entitlements. Emyn uses:
  `group.com.stylemac.Emyn.VirtualCameraExtension`.

## Troubleshooting

Check embedded profiles:

```bash
find /Applications/Emyn.app -name embedded.provisionprofile -print
```

Expected output:

```text
/Applications/Emyn.app/Contents/embedded.provisionprofile
/Applications/Emyn.app/Contents/Library/SystemExtensions/com.stylemac.Emyn.VirtualCameraExtension.systemextension/Contents/embedded.provisionprofile
```

Check signatures:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Emyn.app
spctl --assess --type execute --verbose=4 /Applications/Emyn.app
```

For a Developer ID release, `spctl` should report `accepted` and `source=Notarized Developer ID`.

For a development-signed local build, `codesign` should verify, but `spctl` may reject it. That is expected because it is not a Developer ID notarized app. The app can still launch on registered Macs when the development profiles match.

If Finder says `The application "Emyn.app" can't be opened`, inspect launch-time signing failures:

```bash
/usr/bin/log show --last 10m --style compact --predicate 'process == "amfid" OR eventMessage CONTAINS[c] "Emyn"'
```

`No matching profile found` means the app was signed with restricted entitlements but the matching embedded provisioning profile is missing, is for the wrong bundle ID, is for the wrong team, or does not contain the signing certificate.

If ScreenCaptureKit reports that the user declined TCCs even though System Settings shows Emyn enabled under Screen & System Audio Recording, reset the stale TCC row for the bundle identifier:

```bash
tccutil reset ScreenCapture com.stylemac.Emyn
```

Then quit Emyn, reopen `/Applications/Emyn.app`, trigger the window picker again, approve the system prompt, and relaunch Emyn once more. This can happen after switching from a development-signed build to a Developer ID notarized build because macOS may keep a visible permission row whose stored code requirement no longer matches the app's current signature.

If the targeted reset does not clear the stale state, reset the full screen-capture service and re-grant access to the apps that need it:

```bash
tccutil reset ScreenCapture
```

## Apple References

- [Developer ID support](https://developer.apple.com/support/developer-id/)
- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Create a development provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/)
- [Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)
- [Edit, download, or delete provisioning profiles](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)
- [TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
