//! Low-level CGEventTap wrapper for cursor/keyboard capture.
//!
//! Installs a session-level event tap that:
//! - Intercepts all mouse and keyboard events system-wide
//! - Hides the system cursor
//! - Remaps mouse coordinates from the caller's view bounds to the target app's window bounds
//! - Forwards all events to the target app pid via SkyLight SPI
//! - Detects a triple-Option-key tap within a configurable window as an escape sequence

use std::ffi::{c_char, c_void};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex, OnceLock,
};
use std::thread;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

// ── FFI ───────────────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
struct RawPoint {
    x: f64,
    y: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
struct RawSize {
    width: f64,
    height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
struct RawRect {
    origin: RawPoint,
    size: RawSize,
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

    fn CGEventCreateKeyboardEvent(
        source: *const c_void,
        virtual_key: u16,
        key_down: bool,
    ) -> *mut c_void;

    fn CGEventSourceCreate(state_id: u32) -> *mut c_void;

    fn CGEventGetLocation(event: *mut c_void) -> RawPoint;

    fn CGEventSetLocation(event: *mut c_void, x: f64, y: f64);

    fn CGEventSetFlags(event: *mut c_void, flags: u64);

    fn CGEventSetTimestamp(event: *mut c_void, timestamp: u64);

    fn CGEventPostToPid(pid: i32, event: *mut c_void);

    fn CGEventGetIntegerValueField(event: *mut c_void, field: u32) -> i64;
    fn CGEventSetIntegerValueField(event: *mut c_void, field: u32, value: i64);

    /// Returns the CGEventFlags bitmask for an event.
    /// This is the correct API for reading modifier state — there is no
    /// CGEventField entry for flags; using GetIntegerValueField would read the
    /// wrong field (field 12 = kCGScrollWheelEventDeltaAxis2).
    fn CGEventGetFlags(event: *mut c_void) -> u64;

    fn CGDisplayHideCursor(display: u32) -> i32;
    fn CGDisplayShowCursor(display: u32) -> i32;
    fn CGWarpMouseCursorPosition(x: f64, y: f64) -> i32;
    fn CGAssociateMouseAndMouseCursorPosition(connected: bool) -> i32;
    fn CGMainDisplayID() -> u32;
    fn CGDisplayBounds(display: u32) -> RawRect;
    fn CGGetActiveDisplayList(
        max_displays: u32,
        active_displays: *mut u32,
        display_count: *mut u32,
    ) -> i32;
}

extern "C" {
    fn clock_gettime_nsec_np(clock_id: i32) -> u64;
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
// CGEventSourceStateID
const CG_EVENT_SOURCE_STATE_HID_SYSTEM: u32 = 1;
// macOS clock id for uptime nanoseconds, matching mach continuous event timestamps.
const CLOCK_UPTIME_RAW: i32 = 8;

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
// CGEventField: kCGMouseEventClickState / kCGMouseEventButtonNumber
const FIELD_MOUSE_CLICK_STATE: u32 = 1;
const FIELD_MOUSE_BUTTON: u32 = 3;
// CGEventField: kCGMouseEventDeltaX / kCGMouseEventDeltaY. These are logged
// only for diagnostics because they are raw HID deltas, not normal pointer
// speed/acceleration in screen points.
const FIELD_MOUSE_DELTA_X: u32 = 4;
const FIELD_MOUSE_DELTA_Y: u32 = 5;
// CGEventField: kCGEventSourceUserData. Used to recognize events we
// synthesize/forward so they do not recursively feed back into this tap.
const FIELD_EVENT_SOURCE_USER_DATA: u32 = 42;
const FORWARDED_MOUSE_EVENT_MARKER: i64 = 0x45_4d_59_4e_43_55_52_53;

// macOS virtual key codes for Option keys
const VK_OPTION: i64 = 58;
const VK_RIGHT_OPTION: i64 = 61;

// macOS virtual key codes for F1-F12.
const VK_FUNCTION_KEYS: [i64; 12] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111];

// CGEventFlags bit for Option/Alternate
const FLAG_ALTERNATE: u64 = 0x00080000;

fn event_mask() -> u64 {
    let types = [
        EV_LEFT_MOUSE_DOWN,
        EV_LEFT_MOUSE_UP,
        EV_MOUSE_MOVED,
        EV_LEFT_MOUSE_DRAGGED,
        EV_RIGHT_MOUSE_DOWN,
        EV_RIGHT_MOUSE_UP,
        EV_RIGHT_MOUSE_DRAGGED,
        EV_OTHER_MOUSE_DOWN,
        EV_OTHER_MOUSE_UP,
        EV_OTHER_MOUSE_DRAGGED,
        EV_SCROLL_WHEEL,
        EV_KEY_DOWN,
        EV_KEY_UP,
        EV_FLAGS_CHANGED,
    ];
    types.iter().fold(0u64, |acc, &t| acc | (1u64 << t))
}

// ── Session state stored in a Box, pinned for the tap's lifetime ──────────────

pub struct TapState {
    pub target_pid: i32,
    pub target_window_id: Option<u32>,
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
    pub exclude_function_keys: Arc<AtomicBool>,
    pub attach_keyboard_auth_message: bool,
    pub on_mouse_move: Arc<dyn Fn(f64, f64) + Send + Sync>,
    pub on_deactivate: Arc<dyn Fn() + Send + Sync>,
    // Mutable escape-detection state; only touched from the tap callback (main run-loop thread).
    pub alt_press_times: Mutex<Vec<Instant>>,
    // Shared click-group id for down/drag/up sequences routed to a background window.
    pub current_click_group: Mutex<Option<i64>>,
    // Virtual pointer constrained to the controllable view.
    virtual_cursor: Mutex<RawPoint>,
    // Last known location of the hidden WindowServer cursor. We read deltas
    // between event locations to keep system pointer acceleration, while the
    // virtual cursor owns wrapping/clamping behavior.
    hidden_cursor: Mutex<RawPoint>,
    desktop_bounds: RawRect,
    display_bounds: Vec<RawRect>,
    mouse_forwarder: mpsc::Sender<ForwardedMouseEvent>,
    cursor_hidden: AtomicBool,
    last_cursor_debug_log: Mutex<Option<Instant>>,
    last_ignored_forwarded_event_log: Mutex<Option<Instant>>,
    // Pointer back to the port so the callback can re-enable it on timeout.
    pub tap_port: Mutex<*mut c_void>,
}

// Safety: TapState is only mutated from the main run-loop thread inside the
// tap callback. The Mutex fields add the required Sync bound for Arc.
unsafe impl Send for TapState {}
unsafe impl Sync for TapState {}

struct ForwardedMouseEvent {
    target_pid: i32,
    event: usize,
}

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

    if CGEventGetIntegerValueField(event, FIELD_EVENT_SOURCE_USER_DATA)
        == FORWARDED_MOUSE_EVENT_MARKER
    {
        debug_forwarded_event_ignored(state, event_type);
        return std::ptr::null_mut();
    }

    // Re-enable if the system disabled the tap.
    if event_type == EV_TAP_DISABLED_BY_TIMEOUT || event_type == EV_TAP_DISABLED_BY_USER_INPUT {
        debug_event_tap(format_args!(
            "{} received; re-enabling event tap",
            event_type_name(event_type)
        ));
        let port = *state.tap_port.lock().unwrap_or_else(|e| e.into_inner());
        if !port.is_null() {
            CGEventTapEnable(port, true);
        }
        return event;
    }

    // ── Keyboard / modifier events ────────────────────────────────────────────
    if event_type == EV_KEY_DOWN || event_type == EV_KEY_UP || event_type == EV_FLAGS_CHANGED {
        let keycode = CGEventGetIntegerValueField(event, FIELD_KEYCODE);
        let flags = CGEventGetFlags(event);
        log_incoming_key_event(state, event_type, keycode, flags);
        debug_event_tap(format_args!(
            "key event_type={event_type} keycode={keycode} flags=0x{:x}",
            flags
        ));

        // Escape-sequence detection on flagsChanged (Option key down transitions).
        if event_type == EV_FLAGS_CHANGED {
            if keycode == VK_OPTION || keycode == VK_RIGHT_OPTION {
                // CGEventGetFlags returns the modifier-flag bitmask.
                // Option-key DOWN = the Alternate bit is now SET in the flags.
                let flags_field = CGEventGetFlags(event);
                let is_down = flags_field & FLAG_ALTERNATE != 0;
                if is_down {
                    let now = Instant::now();
                    let interval = std::time::Duration::from_millis(state.escape_interval_ms);
                    let mut times = state
                        .alt_press_times
                        .lock()
                        .unwrap_or_else(|e| e.into_inner());
                    times.push(now);
                    times.retain(|t| now.duration_since(*t) <= interval);
                    if times.len() as u32 >= state.escape_taps {
                        times.clear();
                        // Forward the event first, then schedule deactivation.
                        let forward_event = create_forward_keyboard_event(event_type, event);
                        if !forward_event.is_null() {
                            post_keyboard_event_to_target(state, forward_event);
                            CFRelease(forward_event);
                        }
                        // Tear down the grab immediately; the queued Swift
                        // event only updates UI state.
                        stop_tap_and_reveal_cursor(state);
                        let deactivate = Arc::clone(&state.on_deactivate);
                        deactivate();
                        return std::ptr::null_mut();
                    }
                }
            }
        }

        if (event_type == EV_KEY_DOWN || event_type == EV_KEY_UP)
            && state.exclude_function_keys.load(Ordering::Relaxed)
            && is_function_key(keycode)
        {
            return event;
        }

        // Forward the keyboard event to the target via SkyLight.
        let forward_event = create_forward_keyboard_event(event_type, event);
        if !forward_event.is_null() {
            post_keyboard_event_to_target(state, forward_event);
            CFRelease(forward_event);
        }
        return std::ptr::null_mut(); // suppress original
    }

    // ── Mouse events ──────────────────────────────────────────────────────────
    let (cx, cy) = update_virtual_cursor(state, event_type, event);

    // Normalised position (0–1) within the view.
    let norm_x = if state.view_w > 0.0 {
        (cx - state.view_x) / state.view_w
    } else {
        0.5
    };
    let norm_y = if state.view_h > 0.0 {
        (cy - state.view_y) / state.view_h
    } else {
        0.5
    };

    // Fire the software-cursor callback for move/drag events.
    if matches!(
        event_type,
        EV_MOUSE_MOVED | EV_LEFT_MOUSE_DRAGGED | EV_RIGHT_MOUSE_DRAGGED | EV_OTHER_MOUSE_DRAGGED
    ) {
        (state.on_mouse_move)(norm_x, norm_y);
    }

    // Map to target app coordinates.
    let target_x = state.target_x + norm_x * state.target_w;
    let target_y = state.target_y + norm_y * state.target_h;
    let target_local_x = (target_x - state.target_x).clamp(0.0, state.target_w);
    let target_local_y = (target_y - state.target_y).clamp(0.0, state.target_h);

    // Post a remapped, window-stamped copy via both SkyLight and public API.
    let copy = CGEventCreateCopy(event);
    if !copy.is_null() {
        CGEventSetLocation(copy, target_x, target_y);
        CGEventSetIntegerValueField(
            copy,
            FIELD_EVENT_SOURCE_USER_DATA,
            FORWARDED_MOUSE_EVENT_MARKER,
        );
        stamp_mouse_routing_fields(state, event_type, copy, target_local_x, target_local_y);
        enqueue_mouse_event_for_forwarding(state, copy);
    }

    std::ptr::null_mut() // suppress original
}

unsafe fn enqueue_mouse_event_for_forwarding(state: &TapState, event: *mut c_void) {
    if let Err(err) = state.mouse_forwarder.send(ForwardedMouseEvent {
        target_pid: state.target_pid,
        event: event as usize,
    }) {
        debug_event_tap(format_args!(
            "dropping forwarded mouse event because worker is unavailable: {}",
            err
        ));
        CFRelease(event);
    }
}

fn spawn_mouse_forwarder() -> mpsc::Sender<ForwardedMouseEvent> {
    let (sender, receiver) = mpsc::channel::<ForwardedMouseEvent>();
    let _ = thread::Builder::new()
        .name("emyn-mouse-forwarder".to_owned())
        .spawn(move || {
            for forwarded in receiver {
                unsafe {
                    let event = forwarded.event as *mut c_void;
                    let skylight_posted = crate::input::skylight::post_to_pid(
                        forwarded.target_pid as libc::pid_t,
                        event,
                        false,
                    );
                    if !skylight_posted {
                        CGEventPostToPid(forwarded.target_pid, event);
                    }
                    CFRelease(event);
                }
            }
        });
    sender
}

unsafe fn update_virtual_cursor(
    state: &TapState,
    event_type: u32,
    event: *mut c_void,
) -> (f64, f64) {
    // The event location is the hidden system cursor's accelerated position.
    // Taking deltas between locations preserves normal pointer speed while the
    // virtual cursor owns the view-space wrapping behavior.
    let raw_loc = CGEventGetLocation(event);

    let mut cursor = state
        .virtual_cursor
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut hidden_cursor = state
        .hidden_cursor
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let cursor_before = *cursor;
    let hidden_before = *hidden_cursor;
    let mut location_delta = RawPoint { x: 0.0, y: 0.0 };

    if is_mouse_motion_event(event_type) {
        let delta_x = raw_loc.x - hidden_cursor.x;
        let delta_y = raw_loc.y - hidden_cursor.y;
        location_delta = RawPoint {
            x: delta_x,
            y: delta_y,
        };
        apply_wrapped_virtual_cursor_delta(
            &mut cursor,
            delta_x,
            delta_y,
            state.view_x,
            state.view_y,
            state.view_w,
            state.view_h,
        );
    }

    debug_cursor_motion(
        state,
        event_type,
        event,
        raw_loc,
        hidden_before,
        location_delta,
        cursor_before,
        *cursor,
    );

    *hidden_cursor = raw_loc;
    maybe_recenter_hidden_cursor(
        &mut hidden_cursor,
        &state.display_bounds,
        state.desktop_bounds,
    );

    (cursor.x, cursor.y)
}

fn is_mouse_motion_event(event_type: u32) -> bool {
    matches!(
        event_type,
        EV_MOUSE_MOVED | EV_LEFT_MOUSE_DRAGGED | EV_RIGHT_MOUSE_DRAGGED | EV_OTHER_MOUSE_DRAGGED
    )
}

fn apply_wrapped_virtual_cursor_delta(
    cursor: &mut RawPoint,
    delta_x: f64,
    delta_y: f64,
    view_x: f64,
    view_y: f64,
    view_w: f64,
    view_h: f64,
) {
    cursor.x = wrap_coordinate(cursor.x + delta_x, view_x, view_w);
    cursor.y = wrap_coordinate(cursor.y + delta_y, view_y, view_h);
}

fn wrap_coordinate(value: f64, min: f64, length: f64) -> f64 {
    if length <= 0.0 {
        return min;
    }

    let max = min + length;
    if (min..=max).contains(&value) {
        value
    } else {
        min + (value - min).rem_euclid(length)
    }
}

fn hidden_cursor_anchor(view_x: f64, view_y: f64, view_w: f64, view_h: f64) -> RawPoint {
    RawPoint {
        x: view_x + view_w * 0.5,
        y: view_y + view_h * 0.5,
    }
}

unsafe fn debug_cursor_motion(
    state: &TapState,
    event_type: u32,
    event: *mut c_void,
    raw_loc: RawPoint,
    hidden_before: RawPoint,
    location_delta: RawPoint,
    cursor_before: RawPoint,
    cursor_after: RawPoint,
) {
    if !event_tap_debug_enabled() {
        return;
    }

    let now = Instant::now();
    let mut last_log = state
        .last_cursor_debug_log
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let force_log = !is_mouse_motion_event(event_type)
        || location_delta.x.abs() > 64.0
        || location_delta.y.abs() > 64.0;
    let should_log = force_log
        || last_log
            .map(|last| now.duration_since(last).as_millis() >= 250)
            .unwrap_or(true);

    if !should_log {
        return;
    }
    *last_log = Some(now);

    let hid_delta_x = CGEventGetIntegerValueField(event, FIELD_MOUSE_DELTA_X);
    let hid_delta_y = CGEventGetIntegerValueField(event, FIELD_MOUSE_DELTA_Y);
    debug_event_tap(format_args!(
        "cursor event={} raw_loc=({:.1},{:.1}) hidden_prev=({:.1},{:.1}) loc_delta=({:.1},{:.1}) hid_delta=({},{}) virtual=({:.1},{:.1})->({:.1},{:.1}) view=({:.1},{:.1},{:.1},{:.1}) desktop=({:.1},{:.1},{:.1},{:.1})",
        event_type_name(event_type),
        raw_loc.x,
        raw_loc.y,
        hidden_before.x,
        hidden_before.y,
        location_delta.x,
        location_delta.y,
        hid_delta_x,
        hid_delta_y,
        cursor_before.x,
        cursor_before.y,
        cursor_after.x,
        cursor_after.y,
        state.view_x,
        state.view_y,
        state.view_w,
        state.view_h,
        state.desktop_bounds.origin.x,
        state.desktop_bounds.origin.y,
        state.desktop_bounds.size.width,
        state.desktop_bounds.size.height
    ));
}

fn maybe_recenter_hidden_cursor(
    hidden_cursor: &mut RawPoint,
    display_bounds: &[RawRect],
    desktop_bounds: RawRect,
) {
    let bounds = cursor_display_bounds(*hidden_cursor, display_bounds, desktop_bounds);
    if !raw_rect_is_valid(bounds) {
        return;
    }

    let margin = 96.0;
    let min_x = bounds.origin.x;
    let max_x = bounds.origin.x + bounds.size.width;
    let min_y = bounds.origin.y;
    let max_y = bounds.origin.y + bounds.size.height;

    let outside_display = !raw_rect_contains_point(bounds, *hidden_cursor);
    if outside_display
        || hidden_cursor.x <= min_x + margin
        || hidden_cursor.x >= max_x - margin
        || hidden_cursor.y <= min_y + margin
        || hidden_cursor.y >= max_y - margin
    {
        let before = *hidden_cursor;
        *hidden_cursor = RawPoint {
            x: bounds.origin.x + bounds.size.width * 0.5,
            y: bounds.origin.y + bounds.size.height * 0.5,
        };
        debug_event_tap(format_args!(
            "recentering hidden cursor from ({:.1},{:.1}) to ({:.1},{:.1}) bounds=({:.1},{:.1},{:.1},{:.1}) outside_display={} desktop=({:.1},{:.1},{:.1},{:.1}) display_count={}",
            before.x,
            before.y,
            hidden_cursor.x,
            hidden_cursor.y,
            bounds.origin.x,
            bounds.origin.y,
            bounds.size.width,
            bounds.size.height,
            outside_display,
            desktop_bounds.origin.x,
            desktop_bounds.origin.y,
            desktop_bounds.size.width,
            desktop_bounds.size.height,
            display_bounds.len()
        ));
        unsafe {
            warp_hidden_cursor_to(*hidden_cursor);
        }
    }
}

fn cursor_display_bounds(
    point: RawPoint,
    display_bounds: &[RawRect],
    desktop_bounds: RawRect,
) -> RawRect {
    containing_display_bounds(point, display_bounds)
        .or_else(|| nearest_display_bounds(point, display_bounds))
        .unwrap_or(desktop_bounds)
}

fn containing_display_bounds(point: RawPoint, display_bounds: &[RawRect]) -> Option<RawRect> {
    display_bounds
        .iter()
        .copied()
        .find(|bounds| raw_rect_contains_point(*bounds, point))
}

fn nearest_display_bounds(point: RawPoint, display_bounds: &[RawRect]) -> Option<RawRect> {
    display_bounds.iter().copied().min_by(|a, b| {
        raw_rect_distance_squared(*a, point)
            .partial_cmp(&raw_rect_distance_squared(*b, point))
            .unwrap_or(std::cmp::Ordering::Equal)
    })
}

fn raw_rect_distance_squared(rect: RawRect, point: RawPoint) -> f64 {
    let min_x = rect.origin.x;
    let max_x = rect.origin.x + rect.size.width;
    let min_y = rect.origin.y;
    let max_y = rect.origin.y + rect.size.height;

    let dx = if point.x < min_x {
        min_x - point.x
    } else if point.x > max_x {
        point.x - max_x
    } else {
        0.0
    };
    let dy = if point.y < min_y {
        min_y - point.y
    } else if point.y > max_y {
        point.y - max_y
    } else {
        0.0
    };

    dx * dx + dy * dy
}

fn raw_rect_contains_point(rect: RawRect, point: RawPoint) -> bool {
    let max_x = rect.origin.x + rect.size.width;
    let max_y = rect.origin.y + rect.size.height;
    point.x >= rect.origin.x && point.x <= max_x && point.y >= rect.origin.y && point.y <= max_y
}

fn raw_rect_is_valid(rect: RawRect) -> bool {
    rect.size.width > 0.0 && rect.size.height > 0.0
}

unsafe fn warp_hidden_cursor_to(point: RawPoint) {
    CGWarpMouseCursorPosition(point.x, point.y);
    CGAssociateMouseAndMouseCursorPosition(true);
}

unsafe fn active_display_layout(fallback: RawRect) -> (RawRect, Vec<RawRect>) {
    let mut displays = [0u32; 16];
    let mut count = 0u32;
    if CGGetActiveDisplayList(displays.len() as u32, displays.as_mut_ptr(), &mut count) != 0
        || count == 0
    {
        return (fallback, vec![fallback]);
    }

    let mut union: Option<RawRect> = None;
    let mut bounds_list = Vec::new();
    for display in displays.iter().copied().take(count as usize) {
        let bounds = CGDisplayBounds(display);
        if !raw_rect_is_valid(bounds) {
            continue;
        }

        bounds_list.push(bounds);
        union = Some(match union {
            Some(current) => union_raw_rects(current, bounds),
            None => bounds,
        });
    }

    if bounds_list.is_empty() {
        (fallback, vec![fallback])
    } else {
        (union.unwrap_or(fallback), bounds_list)
    }
}

fn union_raw_rects(a: RawRect, b: RawRect) -> RawRect {
    let min_x = a.origin.x.min(b.origin.x);
    let min_y = a.origin.y.min(b.origin.y);
    let max_x = (a.origin.x + a.size.width).max(b.origin.x + b.size.width);
    let max_y = (a.origin.y + a.size.height).max(b.origin.y + b.size.height);

    RawRect {
        origin: RawPoint { x: min_x, y: min_y },
        size: RawSize {
            width: max_x - min_x,
            height: max_y - min_y,
        },
    }
}

fn view_rect(view_x: f64, view_y: f64, view_w: f64, view_h: f64) -> RawRect {
    RawRect {
        origin: RawPoint {
            x: view_x,
            y: view_y,
        },
        size: RawSize {
            width: view_w,
            height: view_h,
        },
    }
}

fn format_display_bounds(bounds: &[RawRect]) -> String {
    bounds
        .iter()
        .map(|rect| {
            format!(
                "({:.1},{:.1},{:.1},{:.1})",
                rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
            )
        })
        .collect::<Vec<_>>()
        .join(";")
}

unsafe fn hide_cursor(state: &TapState) {
    if !state.cursor_hidden.swap(true, Ordering::Relaxed) {
        debug_event_tap(format_args!("hide system cursor"));
        CGDisplayHideCursor(CGMainDisplayID());
    }
}

unsafe fn reveal_cursor(state: &TapState) {
    if state.cursor_hidden.swap(false, Ordering::Relaxed) {
        debug_event_tap(format_args!("show system cursor"));
        CGDisplayShowCursor(CGMainDisplayID());
    }
}

unsafe fn stop_tap_and_reveal_cursor(state: &TapState) {
    debug_event_tap(format_args!("stopping tap and restoring cursor"));
    let port = *state.tap_port.lock().unwrap_or_else(|e| e.into_inner());
    if !port.is_null() {
        CGEventTapEnable(port, false);
    }
    if let Ok(cursor) = state.virtual_cursor.lock() {
        debug_event_tap(format_args!(
            "warping system cursor to virtual cursor ({:.1},{:.1})",
            cursor.x, cursor.y
        ));
        warp_hidden_cursor_to(*cursor);
    }
    reveal_cursor(state);
}

fn log_incoming_key_event(state: &TapState, event_type: u32, keycode: i64, flags: u64) {
    eprintln!(
        "[window-control] incoming key event type={} keycode={} flags=0x{:x} secure_input={:?} target_pid={} target_window_id={:?}",
        event_type_name(event_type),
        keycode,
        flags,
        is_secure_event_input_enabled(),
        state.target_pid,
        state.target_window_id
    );
}

fn event_type_name(event_type: u32) -> &'static str {
    match event_type {
        EV_LEFT_MOUSE_DOWN => "leftMouseDown",
        EV_LEFT_MOUSE_UP => "leftMouseUp",
        EV_RIGHT_MOUSE_DOWN => "rightMouseDown",
        EV_RIGHT_MOUSE_UP => "rightMouseUp",
        EV_MOUSE_MOVED => "mouseMoved",
        EV_LEFT_MOUSE_DRAGGED => "leftMouseDragged",
        EV_RIGHT_MOUSE_DRAGGED => "rightMouseDragged",
        EV_KEY_DOWN => "keyDown",
        EV_KEY_UP => "keyUp",
        EV_FLAGS_CHANGED => "flagsChanged",
        EV_SCROLL_WHEEL => "scrollWheel",
        EV_OTHER_MOUSE_DOWN => "otherMouseDown",
        EV_OTHER_MOUSE_UP => "otherMouseUp",
        EV_OTHER_MOUSE_DRAGGED => "otherMouseDragged",
        EV_TAP_DISABLED_BY_TIMEOUT => "tapDisabledByTimeout",
        EV_TAP_DISABLED_BY_USER_INPUT => "tapDisabledByUserInput",
        _ => "unknown",
    }
}

fn is_function_key(keycode: i64) -> bool {
    VK_FUNCTION_KEYS.contains(&keycode)
}

type IsSecureEventInputEnabledFn = unsafe extern "C" fn() -> u8;

fn is_secure_event_input_enabled() -> Option<bool> {
    static SYM: OnceLock<Option<IsSecureEventInputEnabledFn>> = OnceLock::new();
    let f = *SYM.get_or_init(|| {
        let path = b"/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox\0";
        unsafe {
            libc::dlopen(path.as_ptr() as *const c_char, libc::RTLD_LAZY | libc::RTLD_GLOBAL);
        }

        let ptr = unsafe {
            libc::dlsym(
                libc::RTLD_DEFAULT,
                b"IsSecureEventInputEnabled\0".as_ptr() as *const c_char,
            )
        };

        if ptr.is_null() {
            None
        } else {
            Some(unsafe {
                std::mem::transmute::<*mut c_void, IsSecureEventInputEnabledFn>(ptr)
            })
        }
    });

    f.map(|is_enabled| unsafe { is_enabled() != 0 })
}

unsafe fn create_forward_keyboard_event(event_type: u32, source_event: *mut c_void) -> *mut c_void {
    let keycode = CGEventGetIntegerValueField(source_event, FIELD_KEYCODE);
    if !(0..=u16::MAX as i64).contains(&keycode) {
        return std::ptr::null_mut();
    }

    let key_down = match event_type {
        EV_KEY_DOWN => true,
        EV_KEY_UP => false,
        EV_FLAGS_CHANGED => modifier_key_is_down(keycode, CGEventGetFlags(source_event)),
        _ => return std::ptr::null_mut(),
    };

    let source = CGEventSourceCreate(CG_EVENT_SOURCE_STATE_HID_SYSTEM);
    let event = CGEventCreateKeyboardEvent(source as *const c_void, keycode as u16, key_down);
    if !source.is_null() {
        CFRelease(source);
    }
    if !event.is_null() {
        CGEventSetFlags(event, CGEventGetFlags(source_event));
        CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    }
    event
}

unsafe fn post_keyboard_event_to_target(state: &TapState, event: *mut c_void) {
    post_keyboard_event_to_target_values(
        state.target_pid,
        state.target_window_id,
        state.attach_keyboard_auth_message,
        event,
    );
}

unsafe fn post_keyboard_event_to_target_values(
    target_pid: i32,
    target_window_id: Option<u32>,
    attach_keyboard_auth_message: bool,
    event: *mut c_void,
) {
    let mut skylight_posted = false;
    let mut owner_posted = false;

    if attach_keyboard_auth_message {
        skylight_posted = post_keyboard_event_once(target_pid, true, event);
        if !skylight_posted {
            owner_posted = post_keyboard_event_to_window_owner(target_pid, target_window_id, event);
        }
    } else {
        owner_posted = post_keyboard_event_to_window_owner(target_pid, target_window_id, event);
        if !owner_posted {
            skylight_posted = post_keyboard_event_once(target_pid, false, event);
        }
    }

    debug_event_tap(format_args!(
        "keyboard routed pid={} window_id={:?} auth={} skylight_posted={} owner_psn_posted={}",
        target_pid, target_window_id, attach_keyboard_auth_message, skylight_posted, owner_posted
    ));
}

unsafe fn post_keyboard_event_once(
    target_pid: i32,
    attach_keyboard_auth_message: bool,
    event: *mut c_void,
) -> bool {
    let skylight_posted = crate::input::skylight::post_to_pid(
        target_pid as libc::pid_t,
        event,
        attach_keyboard_auth_message,
    );
    debug_event_tap(format_args!(
        "keyboard post pid={} auth={} skylight_posted={}",
        target_pid, attach_keyboard_auth_message, skylight_posted
    ));
    if !skylight_posted {
        CGEventPostToPid(target_pid, event);
    }
    skylight_posted
}

unsafe fn post_keyboard_event_to_window_owner(
    target_pid: i32,
    target_window_id: Option<u32>,
    event: *mut c_void,
) -> bool {
    target_window_id
        .map(|window_id| {
            crate::input::skylight::post_to_window_owner(
                window_id,
                target_pid as libc::pid_t,
                event,
            )
        })
        .unwrap_or(false)
}

fn debug_event_tap(args: std::fmt::Arguments<'_>) {
    if event_tap_debug_enabled() {
        eprintln!("[event_tap] {args}");
    }
}

fn event_tap_debug_enabled() -> bool {
    std::env::var_os("EMYN_EVENT_TAP_DEBUG").is_some()
}

fn debug_forwarded_event_ignored(state: &TapState, event_type: u32) {
    if !event_tap_debug_enabled() {
        return;
    }

    let now = Instant::now();
    let mut last_log = state
        .last_ignored_forwarded_event_log
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let should_log = last_log
        .map(|last| now.duration_since(last).as_millis() >= 500)
        .unwrap_or(true);
    if should_log {
        *last_log = Some(now);
        debug_event_tap(format_args!(
            "ignoring forwarded {} event re-entering tap",
            event_type_name(event_type)
        ));
    }
}

fn modifier_key_is_down(keycode: i64, flags: u64) -> bool {
    let mask = match keycode {
        55 | 54 => 0x0010_0000, // command
        56 | 60 => 0x0002_0000, // shift
        58 | 61 => FLAG_ALTERNATE,
        59 | 62 => 0x0004_0000, // control
        63 => 0x0080_0000,      // fn
        _ => 0,
    };

    mask != 0 && flags & mask != 0
}

fn is_mouse_down(event_type: u32) -> bool {
    matches!(
        event_type,
        EV_LEFT_MOUSE_DOWN | EV_RIGHT_MOUSE_DOWN | EV_OTHER_MOUSE_DOWN
    )
}

fn is_mouse_up(event_type: u32) -> bool {
    matches!(
        event_type,
        EV_LEFT_MOUSE_UP | EV_RIGHT_MOUSE_UP | EV_OTHER_MOUSE_UP
    )
}

fn is_mouse_drag(event_type: u32) -> bool {
    matches!(
        event_type,
        EV_LEFT_MOUSE_DRAGGED | EV_RIGHT_MOUSE_DRAGGED | EV_OTHER_MOUSE_DRAGGED
    )
}

fn is_button_mouse_event(event_type: u32) -> bool {
    is_mouse_down(event_type) || is_mouse_up(event_type) || is_mouse_drag(event_type)
}

fn new_click_group_id() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as i64
}

fn click_group_for_event(state: &TapState, event_type: u32) -> Option<i64> {
    if is_mouse_down(event_type) {
        let id = new_click_group_id();
        if let Ok(mut group) = state.current_click_group.lock() {
            *group = Some(id);
        }
        return Some(id);
    }

    if is_mouse_drag(event_type) || is_mouse_up(event_type) {
        return state
            .current_click_group
            .lock()
            .ok()
            .and_then(|group| *group);
    }

    None
}

fn clear_click_group_if_needed(state: &TapState, event_type: u32) {
    if is_mouse_up(event_type) {
        if let Ok(mut group) = state.current_click_group.lock() {
            *group = None;
        }
    }
}

unsafe fn button_number_for_event(event_type: u32, event: *mut c_void) -> Option<i64> {
    match event_type {
        EV_LEFT_MOUSE_DOWN | EV_LEFT_MOUSE_UP | EV_LEFT_MOUSE_DRAGGED => Some(0),
        EV_RIGHT_MOUSE_DOWN | EV_RIGHT_MOUSE_UP | EV_RIGHT_MOUSE_DRAGGED => Some(1),
        EV_OTHER_MOUSE_DOWN | EV_OTHER_MOUSE_UP | EV_OTHER_MOUSE_DRAGGED => {
            let button = CGEventGetIntegerValueField(event, FIELD_MOUSE_BUTTON);
            Some(if button >= 0 { button } else { 2 })
        }
        _ => None,
    }
}

unsafe fn click_state_for_event(event_type: u32, event: *mut c_void) -> i64 {
    let click_state = CGEventGetIntegerValueField(event, FIELD_MOUSE_CLICK_STATE);
    if click_state > 0 {
        click_state
    } else if is_button_mouse_event(event_type) {
        1
    } else {
        0
    }
}

unsafe fn stamp_mouse_routing_fields(
    state: &TapState,
    event_type: u32,
    event: *mut c_void,
    local_x: f64,
    local_y: f64,
) {
    crate::input::skylight::set_window_location(event, local_x, local_y);
    crate::input::skylight::set_integer_field(event, 40, state.target_pid as i64);

    let Some(window_id) = state.target_window_id else {
        return;
    };

    let window_id = window_id as i64;
    let set = |field: u32, value: i64| {
        crate::input::skylight::set_integer_field(event, field, value);
    };

    set(51, window_id);
    set(91, window_id);
    set(92, window_id);

    if event_type == EV_SCROLL_WHEEL {
        return;
    }

    if is_button_mouse_event(event_type) {
        set(1, click_state_for_event(event_type, event));
        if let Some(button) = button_number_for_event(event_type, event) {
            set(3, button);
        }
        set(7, 3);
        if let Some(group_id) = click_group_for_event(state, event_type) {
            set(58, group_id);
        }
        clear_click_group_if_needed(state, event_type);
    }
}

pub fn forward_keyboard_event_for_testing(
    target_pid: i32,
    target_window_id: Option<u32>,
    attach_keyboard_auth_message: bool,
    keycode: u16,
    key_down: bool,
    flags: u64,
) -> anyhow::Result<()> {
    unsafe {
        let source = CGEventSourceCreate(CG_EVENT_SOURCE_STATE_HID_SYSTEM);
        let event = CGEventCreateKeyboardEvent(source as *const c_void, keycode, key_down);
        if !source.is_null() {
            CFRelease(source);
        }
        if event.is_null() {
            anyhow::bail!("CGEventCreateKeyboardEvent failed");
        }

        CGEventSetFlags(event, flags);
        CGEventSetTimestamp(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        post_keyboard_event_to_target_values(
            target_pid,
            target_window_id,
            attach_keyboard_auth_message,
            event,
        );
        CFRelease(event);
    }

    Ok(())
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
        target_window_id: Option<u32>,
        view_x: f64,
        view_y: f64,
        view_w: f64,
        view_h: f64,
        target_x: f64,
        target_y: f64,
        target_w: f64,
        target_h: f64,
        escape_taps: u32,
        escape_interval_ms: u64,
        exclude_function_keys: Arc<AtomicBool>,
        attach_keyboard_auth_message: bool,
        on_mouse_move: Arc<dyn Fn(f64, f64) + Send + Sync>,
        on_deactivate: Arc<dyn Fn() + Send + Sync>,
    ) -> anyhow::Result<Self> {
        eprintln!(
            "[window-control] starting event tap target_pid={} target_window_id={:?} secure_input={:?} exclude_function_keys={} attach_keyboard_auth_message={} event_mask=0x{:x}",
            target_pid,
            target_window_id,
            is_secure_event_input_enabled(),
            exclude_function_keys.load(Ordering::Relaxed),
            attach_keyboard_auth_message,
            event_mask()
        );

        let initial_cursor = hidden_cursor_anchor(view_x, view_y, view_w, view_h);
        let (desktop_bounds, display_bounds) =
            unsafe { active_display_layout(view_rect(view_x, view_y, view_w, view_h)) };
        let mouse_forwarder = spawn_mouse_forwarder();
        debug_event_tap(format_args!(
            "cursor setup view=({:.1},{:.1},{:.1},{:.1}) target=({:.1},{:.1},{:.1},{:.1}) desktop=({:.1},{:.1},{:.1},{:.1}) displays={} display_bounds={} initial=({:.1},{:.1})",
            view_x,
            view_y,
            view_w,
            view_h,
            target_x,
            target_y,
            target_w,
            target_h,
            desktop_bounds.origin.x,
            desktop_bounds.origin.y,
            desktop_bounds.size.width,
            desktop_bounds.size.height,
            display_bounds.len(),
            format_display_bounds(&display_bounds),
            initial_cursor.x,
            initial_cursor.y
        ));
        let state = Box::new(TapState {
            target_pid,
            target_window_id,
            view_x,
            view_y,
            view_w,
            view_h,
            target_x,
            target_y,
            target_w,
            target_h,
            escape_taps,
            escape_interval_ms,
            exclude_function_keys,
            attach_keyboard_auth_message,
            on_mouse_move,
            on_deactivate,
            alt_press_times: Mutex::new(Vec::new()),
            current_click_group: Mutex::new(None),
            virtual_cursor: Mutex::new(initial_cursor),
            hidden_cursor: Mutex::new(initial_cursor),
            desktop_bounds,
            display_bounds,
            mouse_forwarder,
            cursor_hidden: AtomicBool::new(false),
            last_cursor_debug_log: Mutex::new(None),
            last_ignored_forwarded_event_log: Mutex::new(None),
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

        let run_loop_source =
            unsafe { CFMachPortCreateRunLoopSource(std::ptr::null(), tap_port, 0) };

        unsafe {
            let common_modes = kCFRunLoopCommonModes;
            CFRunLoopAddSource(CFRunLoopGetMain(), run_loop_source, common_modes);
            CGEventTapEnable(tap_port, true);
            hide_cursor(&state);
            warp_hidden_cursor_to(initial_cursor);
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
            stop_tap_and_reveal_cursor(&self._state);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn virtual_cursor_wraps_left_to_right() {
        let mut cursor = RawPoint { x: 50.0, y: 50.0 };

        apply_wrapped_virtual_cursor_delta(&mut cursor, -75.0, 0.0, 0.0, 0.0, 100.0, 100.0);

        assert_eq!(cursor.x, 75.0);
        assert_eq!(cursor.y, 50.0);
    }

    #[test]
    fn virtual_cursor_wraps_right_to_left() {
        let mut cursor = RawPoint { x: 50.0, y: 50.0 };

        apply_wrapped_virtual_cursor_delta(&mut cursor, 75.0, 0.0, 0.0, 0.0, 100.0, 100.0);

        assert_eq!(cursor.x, 25.0);
        assert_eq!(cursor.y, 50.0);
    }

    #[test]
    fn virtual_cursor_wraps_each_axis_independently() {
        let mut cursor = RawPoint { x: 50.0, y: 50.0 };

        apply_wrapped_virtual_cursor_delta(&mut cursor, 75.0, -75.0, 0.0, 0.0, 100.0, 100.0);

        assert_eq!(cursor.x, 25.0);
        assert_eq!(cursor.y, 75.0);
    }

    #[test]
    fn virtual_cursor_stays_on_exact_edges() {
        let mut cursor = RawPoint { x: 50.0, y: 50.0 };

        apply_wrapped_virtual_cursor_delta(&mut cursor, 50.0, -50.0, 0.0, 0.0, 100.0, 100.0);

        assert_eq!(cursor.x, 100.0);
        assert_eq!(cursor.y, 0.0);
    }

    #[test]
    fn cursor_recenter_uses_containing_display_not_union() {
        let displays = [
            RawRect {
                origin: RawPoint { x: 0.0, y: 0.0 },
                size: RawSize {
                    width: 1728.0,
                    height: 1117.0,
                },
            },
            RawRect {
                origin: RawPoint { x: 1728.0, y: 0.0 },
                size: RawSize {
                    width: 2696.0,
                    height: 1728.0,
                },
            },
        ];
        let point = RawPoint {
            x: 1700.0,
            y: 700.0,
        };

        let bounds = containing_display_bounds(point, &displays).unwrap();

        assert_eq!(bounds, displays[0]);
    }

    #[test]
    fn cursor_recenter_uses_real_display_for_internal_desktop_gap() {
        let desktop = RawRect {
            origin: RawPoint { x: 0.0, y: 0.0 },
            size: RawSize {
                width: 4424.0,
                height: 1728.0,
            },
        };
        let displays = [
            RawRect {
                origin: RawPoint { x: 0.0, y: 0.0 },
                size: RawSize {
                    width: 3072.0,
                    height: 1728.0,
                },
            },
            RawRect {
                origin: RawPoint {
                    x: 3072.0,
                    y: 352.0,
                },
                size: RawSize {
                    width: 1352.0,
                    height: 878.0,
                },
            },
        ];
        let gap_point = RawPoint {
            x: 3200.0,
            y: 100.0,
        };

        let bounds = cursor_display_bounds(gap_point, &displays, desktop);

        assert_ne!(bounds, desktop);
        assert!(displays.contains(&bounds));
    }
}
