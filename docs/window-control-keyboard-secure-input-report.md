# Window Control Keyboard Capture Report

## Summary

Window control can forward mouse and scroll events, but keyboard forwarding is unavailable whenever macOS Secure Keyboard Entry / Secure Event Input is enabled by any app. The important check is the global HIToolbox `IsSecureEventInputEnabled()` result, not the `kCGSSessionSecureInputPID` value from `CGSessionCopyCurrentDictionary()`.

The working diagnosis after closing 1Password is:

- Normal keys were not reaching Emyn's event tap because Secure Keyboard Entry was enabled system-wide.
- The session dictionary PID was misleading. It represented the focused app associated with the session state, not the app that originally enabled Secure Keyboard Entry.
- Calling `DisableSecureEventInput()` from Emyn is the wrong fix. Emyn should not try to clear another app's secure-input state, and PID-based guards built on the session dictionary can misfire.

## Current Architecture

The window control path is:

1. `WindowControlCoordinator.activate(...)` is called from the SwiftUI UI.
2. The coordinator checks Accessibility and Input Monitoring permission.
3. The coordinator checks `IsSecureEventInputEnabled()`.
4. The coordinator creates a `WindowCaptureSession`.
5. `WindowCaptureSession.activate(...)` calls `activate_without_raise(...)` for the target window when a target window id exists.
6. `EventTapSession::start(...)` creates a session-level `CGEventTapCreate(...)` event tap.
7. The tap callback receives source mouse/keyboard events, remaps mouse events, and forwards keyboard events to the target via SkyLight.

The important keyboard capture code is in:

- `/Users/terhechte/Developer/Swift/Emyn/Emyn/WindowControlCoordinator.swift`
- `/Users/terhechte/Developer/Swift/Emyn/platform-macos/src/capture_session.rs`
- `/Users/terhechte/Developer/Swift/Emyn/platform-macos/src/event_tap.rs`

## What Works

- Accessibility permission is granted.
- Input Monitoring permission is granted.
- The CG event tap is created successfully.
- Mouse events are captured and forwarded.
- Scroll events are captured and forwarded.
- The target PID and target window id are known.
- SkyLight mouse routing is working.

## What Does Not Work While Secure Keyboard Entry Is Enabled

- Normal source `keyDown` and `keyUp` events do not arrive at the event tap.
- Text entry into Ghostty or ChatGPT does not happen.
- Keyboard shortcuts such as `alt+2` do not reach the target.
- Only limited modifier changes, such as `flagsChanged`, may still appear.

This failure happens before SkyLight delivery. The target app never receives letters because Emyn never sees the source `keyDown` / `keyUp` events to forward.

## Important macOS Semantics

The HIToolbox SDK header describes Secure Event Input this way:

- When enabled, keyboard input goes only to the app with keyboard focus.
- Keyboard input is not echoed to other apps using event-monitoring targets.
- Password controls automatically enter secure input mode when focused.
- Terminal apps can expose Secure Keyboard Entry.
- Apps such as 1Password can enable secure input while sensitive fields or flows are active.
- `IsSecureEventInputEnabled()` reports whether Secure Event Input is enabled by any process, not just the current process.

The correct user-facing behavior is therefore:

- If `IsSecureEventInputEnabled()` is false, keyboard forwarding can proceed normally.
- If `IsSecureEventInputEnabled()` is true, mouse/scroll control can still proceed, but keyboard forwarding should be reported as unavailable until the blocker releases Secure Keyboard Entry.

## Why `kCGSSessionSecureInputPID` Should Not Be Used As Owner

`CGSessionCopyCurrentDictionary()` may include `kCGSSessionSecureInputPID`, but this value should not be treated as the process that enabled Secure Keyboard Entry. In the observed failure it pointed at Emyn, even though closing 1Password released the blocker.

That makes PID-based ownership logic unsafe for this use case. It can cause Emyn to blame itself and try to call `DisableSecureEventInput()`, even though another app is responsible for the system-wide secure-input state.

## Why `DisableSecureEventInput()` Should Not Be Used Here

Emyn should not call `DisableSecureEventInput()` as part of window control activation:

- It may not clear the real blocker.
- It can misfire when the session dictionary PID points at Emyn.
- It can interfere with legitimate secure-entry state owned by another app.
- It hides the real user action needed: release the password field, 1Password prompt, or terminal Secure Keyboard Entry mode.

## Recommended Behavior

Window control should:

1. Check `IsSecureEventInputEnabled()` during activation.
2. Start mouse/scroll control normally.
3. If secure input is enabled, show a clear status message:

   ```text
   keyboard forwarding unavailable: another app has Secure Keyboard Entry enabled (e.g. a password field, 1Password, or a terminal's Secure Keyboard Entry)
   ```

4. Poll `IsSecureEventInputEnabled()` while the session is active.
5. Update the status live when the blocker releases Secure Keyboard Entry.
6. Avoid naming a PID or app as the owner unless a separate, reliable owner source is found.

## Current Working Conclusion

The keyboard events were not missing because the target window rejected them. They were missing because Secure Keyboard Entry was enabled system-wide, which prevents Emyn's source event tap from observing normal key events. The robust fix is to gate keyboard forwarding on `IsSecureEventInputEnabled()` and tell the user when another app is blocking capture.
