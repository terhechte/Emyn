//! uniffi-exposed CaptureSession: a system-level cursor/keyboard grab that
//! forwards all input to a target app pid.
//!
//! uniffi 0.29 has a proc-macro bug where Arc<dyn CallbackTrait> cannot appear
//! in exported function signatures (FfiConverterArc is not implemented for dyn Trait).
//! We work around it by using a polled event queue instead of push callbacks.
//!
//! Swift usage:
//! ```swift
//! let session = CaptureSession(targetPid: pid)
//! try session.activate(
//!     viewX: 0, viewY: 0, viewW: 800, viewH: 600,
//!     targetX: 100, targetY: 50, targetW: 1280, targetH: 800,
//!     escapeTaps: 3, escapeIntervalMs: 1000
//! )
//! // Poll on a ~16ms Timer:
//! while let event = session.pollEvent() {
//!     switch event {
//!     case .mouseMove(let x, let y): renderSoftwareCursor(x: x, y: y)
//!     case .deactivated: endCapture()
//!     }
//! }
//! session.deactivate()
//! ```

use crate::event_tap::EventTapSession;
use std::collections::VecDeque;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

// ── Data types exposed to Swift ───────────────────────────────────────────────

#[derive(uniffi::Record, Clone, Debug)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Events produced by the capture session, polled from Swift via `poll_event`.
#[derive(uniffi::Enum, Clone, Debug)]
pub enum CaptureEvent {
    /// Normalised (0–1) cursor position within the host view.
    MouseMove { norm_x: f64, norm_y: f64 },
    /// The escape sequence (triple Option) was detected; session is now inactive.
    Deactivated,
}

// ── Error type ────────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CaptureError {
    #[error("A capture session is already active")]
    AlreadyActive,
    #[error("CGEventTapCreate failed: {message}")]
    TapCreationFailed { message: String },
    #[error("Internal lock error")]
    InternalError,
}

// ── CaptureSession ────────────────────────────────────────────────────────────

/// Shared event queue: the tap callback pushes, Swift polls via poll_event().
type EventQueue = Arc<Mutex<VecDeque<CaptureEvent>>>;

#[derive(uniffi::Object)]
pub struct CaptureSession {
    target_pid: i32,
    tap: Mutex<Option<EventTapSession>>,
    queue: EventQueue,
    exclude_function_keys: Arc<AtomicBool>,
}

impl CaptureSession {
    fn activate_internal(
        &self,
        view_x: f64,
        view_y: f64,
        view_w: f64,
        view_h: f64,
        target_x: f64,
        target_y: f64,
        target_w: f64,
        target_h: f64,
        target_window_id: Option<u32>,
        escape_taps: u32,
        escape_interval_ms: u64,
    ) -> Result<(), CaptureError> {
        let mut tap_guard = self.tap.lock().map_err(|_| CaptureError::InternalError)?;
        if tap_guard.is_some() {
            return Err(CaptureError::AlreadyActive);
        }

        let queue_move = Arc::clone(&self.queue);
        let on_mouse_move: Arc<dyn Fn(f64, f64) + Send + Sync> = Arc::new(move |x, y| {
            if let Ok(mut q) = queue_move.lock() {
                // Keep the queue bounded to avoid unbounded growth.
                if q.len() < 128 {
                    q.push_back(CaptureEvent::MouseMove {
                        norm_x: x,
                        norm_y: y,
                    });
                } else {
                    // Overwrite last entry with latest position (tail-drop the backlog).
                    if let Some(last) = q.back_mut() {
                        *last = CaptureEvent::MouseMove {
                            norm_x: x,
                            norm_y: y,
                        };
                    }
                }
            }
        });

        let queue_deact = Arc::clone(&self.queue);
        let on_deactivate: Arc<dyn Fn() + Send + Sync> = Arc::new(move || {
            if let Ok(mut q) = queue_deact.lock() {
                q.push_back(CaptureEvent::Deactivated);
            }
        });

        if let Some(window_id) = target_window_id {
            let _ = crate::input::skylight::activate_without_raise(
                self.target_pid as libc::pid_t,
                window_id,
            );
        }

        let session = EventTapSession::start(
            self.target_pid,
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
            Arc::clone(&self.exclude_function_keys),
            on_mouse_move,
            on_deactivate,
        )
        .map_err(|e| CaptureError::TapCreationFailed {
            message: e.to_string(),
        })?;

        *tap_guard = Some(session);
        Ok(())
    }
}

#[uniffi::export]
impl CaptureSession {
    #[uniffi::constructor]
    pub fn new(target_pid: i32) -> Arc<Self> {
        Arc::new(CaptureSession {
            target_pid,
            tap: Mutex::new(None),
            queue: Arc::new(Mutex::new(VecDeque::new())),
            exclude_function_keys: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Start capturing. All coordinates must be in CG screen space (top-left
    /// origin, y increasing downward — same as CGEventGetLocation and the AX API).
    ///
    /// Call `poll_event()` on a timer (~16 ms) after this returns to consume events.
    pub fn activate(
        &self,
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
    ) -> Result<(), CaptureError> {
        self.activate_internal(
            view_x,
            view_y,
            view_w,
            view_h,
            target_x,
            target_y,
            target_w,
            target_h,
            None,
            escape_taps,
            escape_interval_ms,
        )
    }

    /// Convenience: activate with `Rect` structs and default escape settings
    /// (3 Option-key taps within 1 second).
    pub fn activate_with_rects(
        &self,
        view_rect: Rect,
        target_rect: Rect,
    ) -> Result<(), CaptureError> {
        self.activate(
            view_rect.x,
            view_rect.y,
            view_rect.width,
            view_rect.height,
            target_rect.x,
            target_rect.y,
            target_rect.width,
            target_rect.height,
            3,
            1000,
        )
    }

    /// Activate with a selected CGWindowID so forwarded mouse events carry
    /// window-local hit-test coordinates and background-window routing fields.
    pub fn activate_with_window_id(
        &self,
        view_rect: Rect,
        target_rect: Rect,
        target_window_id: u32,
    ) -> Result<(), CaptureError> {
        self.activate_internal(
            view_rect.x,
            view_rect.y,
            view_rect.width,
            view_rect.height,
            target_rect.x,
            target_rect.y,
            target_rect.width,
            target_rect.height,
            Some(target_window_id),
            3,
            1000,
        )
    }

    /// Stop capturing and restore the system cursor. Idempotent.
    pub fn deactivate(&self) {
        if let Ok(mut guard) = self.tap.lock() {
            *guard = None;
        }
    }

    /// Returns `true` when the tap is currently active.
    pub fn is_active(&self) -> bool {
        self.tap.lock().map(|g| g.is_some()).unwrap_or(false)
    }

    /// Returns the next pending event, or `None` when the queue is empty.
    ///
    /// Recommended usage: call on a ~16 ms timer in Swift:
    /// ```swift
    /// while let event = session.pollEvent() { handle(event) }
    /// ```
    pub fn poll_event(&self) -> Option<CaptureEvent> {
        self.queue.lock().ok()?.pop_front()
    }

    /// Drain all pending events at once (useful for catching up after a pause).
    pub fn drain_events(&self) -> Vec<CaptureEvent> {
        self.queue
            .lock()
            .ok()
            .map(|mut q| q.drain(..).collect())
            .unwrap_or_default()
    }

    /// When enabled, F1-F12 are not forwarded to the controlled app/window and
    /// continue through the original event stream.
    pub fn set_exclude_function_keys(&self, exclude: bool) {
        self.exclude_function_keys.store(exclude, Ordering::Relaxed);
    }

    /// Returns whether F1-F12 are currently excluded from forwarding.
    pub fn exclude_function_keys(&self) -> bool {
        self.exclude_function_keys.load(Ordering::Relaxed)
    }

    /// Target PID this session controls.
    pub fn target_pid(&self) -> i32 {
        self.target_pid
    }
}

// ── Helper: AX window bounds ──────────────────────────────────────────────────

/// Return the focused window bounds of `pid` in CG screen space (top-left
/// origin, y increasing downward).
///
/// Tries `AXFocusedWindow` first; falls back to the first element of `AXWindows`.
/// Returns `None` when the process is not accessible or has no windows.
#[uniffi::export]
pub fn get_focused_window_bounds(pid: i32) -> Option<Rect> {
    use crate::ax::bindings::{
        AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
        AXValueGetValue, kAXValueCGPointType, kAXValueCGSizeType,
        kAXErrorSuccess, AXUIElementRef,
    };
    use core_foundation::base::{CFRelease, CFTypeRef, TCFType};
    use core_foundation::string::CFString as CFStr;

    #[repr(C)] struct CGPoint { x: f64, y: f64 }
    #[repr(C)] struct CGSize  { w: f64, h: f64 }

    unsafe fn read_pos_size(window: AXUIElementRef) -> Option<Rect> {
        let pos_attr = CFStr::new("AXPosition");
        let sz_attr  = CFStr::new("AXSize");

        let mut pos_ref: CFTypeRef = std::ptr::null();
        let mut sz_ref:  CFTypeRef = std::ptr::null();

        if AXUIElementCopyAttributeValue(
            window, pos_attr.as_concrete_TypeRef(), &mut pos_ref) != kAXErrorSuccess
            || pos_ref.is_null() { return None; }

        if AXUIElementCopyAttributeValue(
            window, sz_attr.as_concrete_TypeRef(), &mut sz_ref) != kAXErrorSuccess
            || sz_ref.is_null() { CFRelease(pos_ref); return None; }

        let mut pos = CGPoint { x: 0.0, y: 0.0 };
        let mut sz  = CGSize  { w: 0.0, h: 0.0 };

        let ok1 = AXValueGetValue(pos_ref as _, kAXValueCGPointType,
            &mut pos as *mut _ as *mut std::ffi::c_void);
        let ok2 = AXValueGetValue(sz_ref  as _, kAXValueCGSizeType,
            &mut sz  as *mut _ as *mut std::ffi::c_void);

        CFRelease(pos_ref);
        CFRelease(sz_ref);

        if ok1 && ok2 && sz.w > 0.0 && sz.h > 0.0 {
            Some(Rect { x: pos.x, y: pos.y, width: sz.w, height: sz.h })
        } else {
            None
        }
    }

    unsafe {
        let app = AXUIElementCreateApplication(pid);
        if app.is_null() { return None; }

        // Try AXFocusedWindow.
        let focused_attr = CFStr::new("AXFocusedWindow");
        let mut win_ref: CFTypeRef = std::ptr::null();
        let err = AXUIElementCopyAttributeValue(
            app, focused_attr.as_concrete_TypeRef(), &mut win_ref);

        if err == kAXErrorSuccess && !win_ref.is_null() {
            let r = read_pos_size(win_ref as AXUIElementRef);
            CFRelease(win_ref);
            CFRelease(app as CFTypeRef);
            return r;
        }

        // Fallback: first window in AXWindows list.
        let windows = crate::ax::bindings::copy_ax_windows(app);
        CFRelease(app as CFTypeRef);

        if let Some(&first) = windows.first() {
            let r = read_pos_size(first);
            for w in &windows { CFRelease(*w as CFTypeRef); }
            r
        } else {
            None
        }
    }
}
