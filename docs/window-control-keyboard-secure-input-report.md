# Window Control Keyboard Capture Report

## Summary

Window control can forward mouse and scroll events, but it does not receive normal keyboard events from the user's physical keyboard. The current logs show that the app only receives `flagsChanged` events, such as Option press/release, and does not receive `keyDown` or `keyUp` for normal keys.

The strongest current finding is that Secure Event Input is enabled and the owning PID is Emyn itself:

```text
[window-control] disabled own Secure Input attempt=1 remainingOwner=Emyn pid=88569
[window-control] disabled own Secure Input attempt=2 remainingOwner=Emyn pid=88569
[window-control] disabled own Secure Input attempt=3 remainingOwner=Emyn pid=88569
[window-control] disabled own Secure Input attempt=4 remainingOwner=Emyn pid=88569
[window-control] activate requested ax=true inputMonitoring=true secureInputOwner=Emyn pid=88569 bundle=com.stylemac.Emyn executable=.../Emyn.app/Contents/MacOS/Emyn
[window-control] starting event tap target_pid=68170 target_window_id=Some(74143) secure_input=Some(true) exclude_function_keys=true attach_keyboard_auth_message=true event_mask=0xe401cfe
```

This means the failing part is source-side keyboard capture, not target-side SkyLight delivery. The target app never receives letters because Emyn never sees the source `keyDown` / `keyUp` events to forward.

## Current Architecture

The window control path is:

1. `WindowControlCoordinator.activate(...)` is called from the SwiftUI UI.
2. The coordinator checks Accessibility and Input Monitoring permission.
3. The coordinator creates a `WindowCaptureSession`.
4. `WindowCaptureSession.activate(...)` calls `activate_without_raise(...)` for the target window when a target window id exists.
5. `EventTapSession::start(...)` creates a session-level `CGEventTapCreate(...)` event tap.
6. The tap callback receives source mouse/keyboard events, remaps mouse events, and forwards keyboard events to the target via SkyLight.

The important keyboard capture code is in:

- `/Users/terhechte/Developer/Swift/Emyn/platform-macos/src/event_tap.rs`
- `/Users/terhechte/Developer/Swift/Emyn/platform-macos/src/capture_session.rs`
- `/Users/terhechte/Developer/Swift/Emyn/Emyn/WindowControlCoordinator.swift`

The current diagnostic logging happens in two places:

- Swift activation logs `AXIsProcessTrusted`, `CGPreflightListenEventAccess`, and `kCGSSessionSecureInputPID`.
- Rust event tap startup and key callbacks log `IsSecureEventInputEnabled()`.

## What Works

- Accessibility permission is granted: `ax=true`.
- Input Monitoring permission is granted: `inputMonitoring=true`.
- The CG event tap is created successfully.
- Mouse events are captured and forwarded.
- Scroll events are captured and forwarded.
- Modifier state changes are seen as `flagsChanged`.
- The target PID and target window id are known.
- SkyLight mouse routing is working.

## What Does Not Work

- Normal source `keyDown` and `keyUp` events do not arrive at the event tap.
- Text entry into Ghostty or ChatGPT does not happen.
- Keyboard shortcuts such as `alt+2` do not reach the target.
- Calling `DisableSecureEventInput()` four times from Emyn does not clear the Secure Event Input owner.

## What The Logs Prove

### 1. This is not a missing Input Monitoring permission

The app reports:

```text
inputMonitoring=true
```

If Input Monitoring were missing, the event tap would either fail to start or receive no keyboard-monitorable events. Here it starts and receives at least `flagsChanged`, so the permission state is not the primary issue.

### 2. This is not currently a SkyLight keyboard-posting issue

The keyboard forwarding path cannot be evaluated for letters when no source `keyDown` / `keyUp` event reaches the tap.

The forwarding code only runs after this branch receives a keyboard event:

```rust
if event_type == EV_KEY_DOWN || event_type == EV_KEY_UP || event_type == EV_FLAGS_CHANGED {
    ...
}
```

For letters, that branch is not entered because macOS is not delivering the letter events to the tap.

### 3. Secure Event Input is active during capture

Rust logs:

```text
secure_input=Some(true)
```

That comes from `IsSecureEventInputEnabled()`, which is a system-wide check. The SDK header says this API returns true if Secure Event Input is enabled by any process, not just the current process.

### 4. Emyn is the Secure Event Input owner

Swift logs:

```text
secureInputOwner=Emyn pid=88569
```

That comes from `CGSessionCopyCurrentDictionary()` and the `kCGSSessionSecureInputPID` session key. This is not an external app blocking Emyn. The current process owns the blocking state.

### 5. Repeated disable attempts are not enough

The app calls `DisableSecureEventInput()` four times when Emyn owns Secure Input, but ownership remains with Emyn after each attempt.

This matters because the HIToolbox header says Secure Event Input is reference-counted. Secure Input is not disabled until `DisableSecureEventInput()` has been called the same number of times as `EnableSecureEventInput()`.

## Relevant macOS Semantics

The HIToolbox SDK header describes Secure Event Input this way:

- When enabled, keyboard input goes only to the app with keyboard focus.
- Keyboard input is not echoed to other apps using event-monitoring targets.
- Password controls automatically enter secure input mode when focused.
- The API keeps a count of enable calls.
- Secure input is disabled only after the matching number of disable calls.
- `IsSecureEventInputEnabled()` reports whether any process has enabled it.

This behavior matches the symptoms: Emyn has keyboard focus, Secure Input is enabled, and Emyn's event tap sees only limited modifier state changes instead of normal key events.

## Most Likely Root Causes

### High confidence: source capture is blocked before forwarding

The source event tap is not receiving normal key events. The target app, SkyLight authentication message, and window-targeted posting are downstream of that. They cannot make letters appear if no source key event exists to forward.

### High confidence: Emyn has an unbalanced or immediately re-enabled Secure Input state

Because `DisableSecureEventInput()` is count-based, four unsuccessful disable calls imply one of these:

1. Something in Emyn enabled Secure Input more than four times.
2. Something in Emyn re-enables Secure Input immediately after each disable.
3. The current FFI call is reaching the symbol but should be adjusted to use the exact `OSStatus` return signature and log failures.

### Medium confidence: an AppKit/SwiftUI first responder is still holding keyboard focus

The current preflight calls:

```swift
window.endEditing(for: nil)
window.makeFirstResponder(nil)
```

That may not be enough if SwiftUI restores focus on the same run-loop turn, if a sheet is closing, or if another window/panel remains key. The activation happens directly from a SwiftUI button action, so the UI may still be in a focus transition when the tap starts.

### Medium confidence: the function-key monitor is involved indirectly

`FunctionKeyController` installs:

```swift
NSEvent.addLocalMonitorForEvents(matching: .keyDown)
NSEvent.addGlobalMonitorForEvents(matching: .keyDown)
```

A global monitor should not normally enable Secure Event Input by itself. However, it is now part of Emyn's keyboard-monitoring surface and should be isolated because it is a recent feature and shares the same key-event domain.

### Low confidence: target-side keyboard injection is broken

There may still be target-specific keyboard delivery issues after source capture is fixed, especially for Chromium/Electron apps, Ghostty, and shortcuts. But the current logs do not reach that layer for normal keys.

## Why Mouse And Scroll Still Work

Secure Event Input protects keyboard input. It does not block mouse movement, clicks, or scroll events in the same way. That explains why mouse/scroll can be excellent while text and shortcuts fail completely.

## Why Codex Computer Use Can Still Type

This issue is specific to relaying the user's physical keyboard through Emyn's event tap.

Codex Computer Use does not necessarily depend on capturing the user's physical `keyDown` events from a global/session event tap. It can synthesize keyboard events from tool instructions such as "type this text" or "press this key". In that model, there may be no source hardware key event to observe. Emyn's window-control mode is different: it is trying to grab the user's real keyboard input and forward it.

So the comparison is:

- Codex-style text injection: generate synthetic key/text events directly.
- Emyn window control: capture physical user key events first, then forward them.

The current failure is in the capture-first part.

## Recommended Next Experiments

### 1. Log the exact `DisableSecureEventInput()` result

Change the Swift FFI type from returning `Void` to returning `OSStatus`:

```swift
private typealias HIToolboxStatusFunction = @convention(c) () -> OSStatus
```

Log the returned status for each call. This will show whether the call is succeeding but insufficient, or failing silently.

### 2. Disable until the owner changes, with a bounded maximum

For debugging only, try a larger bounded loop, for example 64 calls, and log:

- attempt number
- `OSStatus`
- `secureInputOwner`
- `IsSecureEventInputEnabled()`

If attempt 5 or 12 clears it, the issue is an unbalanced enable count. If no bounded attempt clears it, the state is being re-enabled or the call is not taking effect.

### 3. Log first responder before and after focus release

Before and after `releaseAppKeyboardFocus(in:)`, log:

- `NSApp.keyWindow`
- each candidate window's `firstResponder`
- `window.makeFirstResponder(nil)` return value

This will show whether Emyn still has an active text/editing responder after the current release attempt.

### 4. Defer activation by one or two main-run-loop turns

Instead of starting window control in the same SwiftUI button action, release focus first, then start capture after a short main-actor yield:

```swift
Task { @MainActor in
    releaseAppKeyboardFocus(in: view.window)
    await Task.yield()
    await Task.yield()
    startCapture()
}
```

If this fixes it, SwiftUI/AppKit is restoring secure input during the current event turn.

### 5. Temporarily stop the function-key monitors while controlling a window

As an isolation test, call `functionKeys.stopMonitoring()` before `windowControl.activate(...)`, and restart it after deactivation.

If Secure Input no longer belongs to Emyn, the function-key controller is involved. If nothing changes, it can be ruled out.

### 6. Log secure input owner at app lifecycle points

Add logs at:

- app launch
- after `functionKeys.startMonitoring()`
- before opening the window picker sheet
- after closing the window picker sheet
- before pressing "Control Window"
- after focus release
- after `WindowCaptureSession.activate(...)`

This will identify when Emyn first becomes the Secure Input owner.

## Suggested Fix Direction

The likely durable fix is:

1. Find the exact moment Emyn enables Secure Event Input.
2. Remove the cause if it is accidental.
3. During window control activation, explicitly leave text/editing focus.
4. Start the capture session only after AppKit/SwiftUI has completed the focus transition.
5. Keep the existing Secure Input owner/status logging, because it gives a clear user-facing reason when another app blocks keyboard capture.

If the function-key monitor is the trigger, replace it with the existing low-level event-tap infrastructure or disable it while window control owns the keyboard.

If the trigger is an AppKit responder or sheet teardown, make window control activation asynchronous:

- button click requests activation
- focus is cleared
- next run-loop turn starts `WindowCaptureSession`

## Current Working Conclusion

The keyboard events are not missing because the target window rejects them. They are missing because Emyn owns Secure Event Input at the exact time its event tap tries to capture the user's keyboard. Until `secure_input=Some(false)` or `secureInputOwner=none` appears before event-tap startup, normal letters should not be expected to appear in the event tap.
