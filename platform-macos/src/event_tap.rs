//! Low-level CGEventTap wrapper for cursor/keyboard capture.
//!
//! Installs a session-level event tap that:
//! - Intercepts all mouse and keyboard events system-wide
//! - Hides the system cursor
//! - Remaps mouse coordinates from the caller's view bounds to the target app's window bounds
//! - Forwards all events to the target app pid via SkyLight SPI
//! - Detects a triple-Option-key tap within a configurable window as an escape sequence

use std::ffi::c_void;
use std::sync::{Arc, Mutex};
use std::time::Instant;

// ── FFI ───────────────────────────────────────────────────────────────────────

#[repr(C)]
struct RawPoint {
    x: f64,
    y: f64,
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events_of_interest: u64,
        callback: *const c_void,
        user_info: *mut c_void,
    ) -> *mut c_void;

    fn CGEventTapEnable(tap: *mut c_void, enable: bool);

    fn CGEventCreateCopy(event: *mut c_void) -> *mut c_void;

    fn CGEventGetLocation(event: *mut c_void) -> RawPoint;

    fn CGEventSetLocation(event: *mut c_void, x: f64, y: f64);

    fn CGEventPostToPid(pid: i32, event: *mut c_void);

    fn CGEventGetIntegerValueField(event: *mut c_void, field: u32) -> i64;

    /// Returns the CGEventFlags bitmask for an event.
    /// This is the correct API for reading modifier state — there is no
    /// CGEventField entry for flags; using GetIntegerValueField would read the
    /// wrong field (field 12 = kCGScrollWheelEventDeltaAxis2).
    fn CGEventGetFlags(event: *mut c_void) -> u64;

    fn CGDisplayHideCursor(display: u32) -> i32;
    fn CGDisplayShowCursor(display: u32) -> i32;
    fn CGWarpMouseCursorPosition(x: f64, y: f64) -> i32;
    fn CGMainDisplayID() -> u32;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFMachPortCreateRunLoopSource(
        allocator: *const c_void,
        port: *mut c_void,
        order: i32,
    ) -> *mut c_void;
    fn CFRunLoopGetMain() -> *mut c_void;
    fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRunLoopRemoveSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
    fn CFRelease(cf_type: *mut c_void);

    static kCFRunLoopCommonModes: *const c_void;
}

// ── Constants ─────────────────────────────────────────────────────────────────

// CGEventTapLocation
const CG_SESSION_EVENT_TAP: u32 = 1;
// CGEventTapPlacement
const CG_HEAD_INSERT_EVENT_TAP: u32 = 0;
// CGEventTapOptions
const CG_DEFAULT_TAP: u32 = 0;

// CGEventType raw values
const EV_LEFT_MOUSE_DOWN: u32 = 1;
const EV_LEFT_MOUSE_UP: u32 = 2;
const EV_RIGHT_MOUSE_DOWN: u32 = 3;
const EV_RIGHT_MOUSE_UP: u32 = 4;
const EV_MOUSE_MOVED: u32 = 5;
const EV_LEFT_MOUSE_DRAGGED: u32 = 6;
const EV_RIGHT_MOUSE_DRAGGED: u32 = 7;
const EV_KEY_DOWN: u32 = 10;
const EV_KEY_UP: u32 = 11;
const EV_FLAGS_CHANGED: u32 = 12;
const EV_SCROLL_WHEEL: u32 = 22;
const EV_OTHER_MOUSE_DOWN: u32 = 25;
const EV_OTHER_MOUSE_UP: u32 = 26;
const EV_OTHER_MOUSE_DRAGGED: u32 = 27;
const EV_TAP_DISABLED_BY_TIMEOUT: u32 = 0xFFFFFFFE;
const EV_TAP_DISABLED_BY_USER_INPUT: u32 = 0xFFFFFFFF;

// CGEventField: kCGKeyboardEventKeycode
const FIELD_KEYCODE: u32 = 9;

// macOS virtual key codes for Option keys
const VK_OPTION: i64 = 58;
const VK_RIGHT_OPTION: i64 = 61;

// CGEventFlags bit for Option/Alternate
const FLAG_ALTERNATE: u64 = 0x00080000;

fn event_mask() -> u64 {
    let types = [
        EV_LEFT_MOUSE_DOWN, EV_LEFT_MOUSE_UP, EV_MOUSE_MOVED,
        EV_LEFT_MOUSE_DRAGGED, EV_RIGHT_MOUSE_DOWN, EV_RIGHT_MOUSE_UP,
        EV_RIGHT_MOUSE_DRAGGED, EV_OTHER_MOUSE_DOWN, EV_OTHER_MOUSE_UP,
        EV_OTHER_MOUSE_DRAGGED, EV_SCROLL_WHEEL,
        EV_KEY_DOWN, EV_KEY_UP, EV_FLAGS_CHANGED,
    ];
    types.iter().fold(0u64, |acc, &t| acc | (1u64 << t))
}

// ── Session state stored in a Box, pinned for the tap's lifetime ──────────────

pub struct TapState {
    pub target_pid: i32,
    pub view_x: f64,
    pub view_y: f64,
    pub view_w: f64,
    pub view_h: f64,
    pub target_x: f64,
    pub target_y: f64,
    pub target_w: f64,
    pub target_h: f64,
    pub escape_taps: u32,
    pub escape_interval_ms: u64,
    pub on_mouse_move: Arc<dyn Fn(f64, f64) + Send + Sync>,
    pub on_deactivate: Arc<dyn Fn() + Send + Sync>,
    // Mutable escape-detection state; only touched from the tap callback (main run-loop thread).
    pub alt_press_times: Mutex<Vec<Instant>>,
    // Pointer back to the port so the callback can re-enable it on timeout.
    pub tap_port: Mutex<*mut c_void>,
}

// Safety: TapState is only mutated from the main run-loop thread inside the
// tap callback. The Mutex fields add the required Sync bound for Arc.
unsafe impl Send for TapState {}
unsafe impl Sync for TapState {}

// ── C-level callback ──────────────────────────────────────────────────────────

/// This is the CGEventTap callback. It runs on the main CFRunLoop thread.
/// Returns null to suppress the event, or a (possibly modified) CGEventRef to pass it through.
unsafe extern "C" fn tap_callback(
    _proxy: *mut c_void,
    event_type: u32,
    event: *mut c_void,
    user_info: *mut c_void,
) -> *mut c_void {
    if user_info.is_null() || event.is_null() {
        return event;
    }

    // Re-cast to TapState. The TapState is kept alive by EventTapSession.
    let state = &*(user_info as *const TapState);

    // Re-enable if the system disabled the tap.
    if event_type == EV_TAP_DISABLED_BY_TIMEOUT || event_type == EV_TAP_DISABLED_BY_USER_INPUT {
        let port = *state.tap_port.lock().unwrap_or_else(|e| e.into_inner());
        if !port.is_null() {
            CGEventTapEnable(port, true);
        }
        return event;
    }

    // ── Keyboard / modifier events ────────────────────────────────────────────
    if event_type == EV_KEY_DOWN || event_type == EV_KEY_UP || event_type == EV_FLAGS_CHANGED {
        // Escape-sequence detection on flagsChanged (Option key down transitions).
        if event_type == EV_FLAGS_CHANGED {
            let keycode = CGEventGetIntegerValueField(event, FIELD_KEYCODE);
            if keycode == VK_OPTION || keycode == VK_RIGHT_OPTION {
                // CGEventGetFlags returns the modifier-flag bitmask.
                // Option-key DOWN = the Alternate bit is now SET in the flags.
                let flags_field = CGEventGetFlags(event);
                let is_down = flags_field & FLAG_ALTERNATE != 0;
                if is_down {
                    let now = Instant::now();
                    let interval = std::time::Duration::from_millis(state.escape_interval_ms);
                    let mut times = state.alt_press_times.lock().unwrap_or_else(|e| e.into_inner());
                    times.push(now);
                    times.retain(|t| now.duration_since(*t) <= interval);
                    if times.len() as u32 >= state.escape_taps {
                        times.clear();
                        // Forward the event first, then schedule deactivation.
                        let copy = CGEventCreateCopy(event);
                        if !copy.is_null() {
                            crate::input::skylight::post_to_pid(
                                state.target_pid as libc::pid_t, copy, true,
                            );
                            CFRelease(copy);
                        }
                        // Trigger deactivation on next run-loop tick.
                        let deactivate = Arc::clone(&state.on_deactivate);
                        // We can call the callback directly since we're already on the main thread.
                        deactivate();
                        return std::ptr::null_mut();
                    }
                }
            }
        }

        // Forward the keyboard event to the target via SkyLight (with auth message).
        let copy = CGEventCreateCopy(event);
        if !copy.is_null() {
            crate::input::skylight::post_to_pid(
                state.target_pid as libc::pid_t, copy, true,
            );
            CFRelease(copy);
        }
        return std::ptr::null_mut(); // suppress original
    }

    // ── Mouse events ──────────────────────────────────────────────────────────
    let raw_loc = CGEventGetLocation(event);
    let (rx, ry) = (raw_loc.x, raw_loc.y);

    // Clamp to view bounds.
    let cx = rx.clamp(state.view_x, state.view_x + state.view_w);
    let cy = ry.clamp(state.view_y, state.view_y + state.view_h);

    // Warp cursor back into view if it strayed.
    if rx != cx || ry != cy {
        CGWarpMouseCursorPosition(cx, cy);
    }

    // Normalised position (0–1) within the view.
    let norm_x = if state.view_w > 0.0 { (cx - state.view_x) / state.view_w } else { 0.5 };
    let norm_y = if state.view_h > 0.0 { (cy - state.view_y) / state.view_h } else { 0.5 };

    // Fire the software-cursor callback for move/drag events.
    if matches!(event_type, EV_MOUSE_MOVED | EV_LEFT_MOUSE_DRAGGED | EV_RIGHT_MOUSE_DRAGGED | EV_OTHER_MOUSE_DRAGGED) {
        (state.on_mouse_move)(norm_x, norm_y);
    }

    // Map to target app coordinates.
    let target_x = state.target_x + norm_x * state.target_w;
    let target_y = state.target_y + norm_y * state.target_h;

    // Post a remapped copy via both SkyLight and public API (belt+suspenders, mouse path).
    let copy = CGEventCreateCopy(event);
    if !copy.is_null() {
        CGEventSetLocation(copy, target_x, target_y);
        crate::input::skylight::post_to_pid(state.target_pid as libc::pid_t, copy, false);
        CGEventPostToPid(state.target_pid, copy);
        CFRelease(copy);
    }

    std::ptr::null_mut() // suppress original
}

// ── Public session type ───────────────────────────────────────────────────────

/// An active event-tap session. Dropping this stops the tap and restores the cursor.
pub struct EventTapSession {
    // Heap-allocated state pointer passed to the C callback. Must outlive the tap.
    _state: Box<TapState>,
    tap_port: *mut c_void,
    run_loop_source: *mut c_void,
}

// Safety: EventTapSession is only used from the main thread but must be
// movable across threads (e.g. into Arc) — raw pointers inside are protected
// by the assumption that stop() is always called from the same thread as start().
unsafe impl Send for EventTapSession {}
unsafe impl Sync for EventTapSession {}

impl EventTapSession {
    /// Install the event tap. Must be called from the main thread.
    /// Returns an error if the tap could not be created (usually missing
    /// Accessibility permission).
    pub fn start(
        target_pid: i32,
        view_x: f64, view_y: f64, view_w: f64, view_h: f64,
        target_x: f64, target_y: f64, target_w: f64, target_h: f64,
        escape_taps: u32,
        escape_interval_ms: u64,
        on_mouse_move: Arc<dyn Fn(f64, f64) + Send + Sync>,
        on_deactivate: Arc<dyn Fn() + Send + Sync>,
    ) -> anyhow::Result<Self> {
        let state = Box::new(TapState {
            target_pid,
            view_x, view_y, view_w, view_h,
            target_x, target_y, target_w, target_h,
            escape_taps,
            escape_interval_ms,
            on_mouse_move,
            on_deactivate,
            alt_press_times: Mutex::new(Vec::new()),
            tap_port: Mutex::new(std::ptr::null_mut()),
        });

        let state_ptr = &*state as *const TapState as *mut c_void;

        let tap_port = unsafe {
            CGEventTapCreate(
                CG_SESSION_EVENT_TAP,
                CG_HEAD_INSERT_EVENT_TAP,
                CG_DEFAULT_TAP,
                event_mask(),
                tap_callback as *const c_void,
                state_ptr,
            )
        };

        if tap_port.is_null() {
            anyhow::bail!(
                "CGEventTapCreate failed — ensure the process has Accessibility permission \
                 (System Settings → Privacy & Security → Accessibility)"
            );
        }

        // Store the port in TapState so the timeout-handler can re-enable it.
        *state.tap_port.lock().unwrap() = tap_port;

        let run_loop_source = unsafe {
            CFMachPortCreateRunLoopSource(std::ptr::null(), tap_port, 0)
        };

        unsafe {
            let common_modes = kCFRunLoopCommonModes;
            CFRunLoopAddSource(CFRunLoopGetMain(), run_loop_source, common_modes);
            CGEventTapEnable(tap_port, true);
            CGDisplayHideCursor(CGMainDisplayID());
        }

        Ok(EventTapSession {
            _state: state,
            tap_port,
            run_loop_source,
        })
    }

    /// Disable the tap and restore the system cursor. Idempotent.
    pub fn stop(&self) {
        unsafe {
            CGEventTapEnable(self.tap_port, false);
            CGDisplayShowCursor(CGMainDisplayID());
            if !self.run_loop_source.is_null() {
                let common_modes = kCFRunLoopCommonModes;
                CFRunLoopRemoveSource(CFRunLoopGetMain(), self.run_loop_source, common_modes);
            }
        }
    }
}

impl Drop for EventTapSession {
    fn drop(&mut self) {
        self.stop();
        unsafe {
            if !self.run_loop_source.is_null() {
                CFRelease(self.run_loop_source);
            }
            if !self.tap_port.is_null() {
                CFRelease(self.tap_port);
            }
        }
    }
}
