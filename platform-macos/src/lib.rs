//! macOS platform backend for cua-driver-rs.
//!
//! Provides background automation on macOS via:
//! - Accessibility (AX) API for UI tree walking and element interaction
//! - CGEvent / SkyLight SPI for background mouse and keyboard injection
//! - NSRunningApplication / NSWorkspace for app enumeration and lifecycle
//! - CGWindow for window enumeration and screenshots

#[cfg(target_os = "macos")]
pub mod ax;
#[cfg(target_os = "macos")]
pub mod apps;
#[cfg(target_os = "macos")]
pub mod windows;
#[cfg(target_os = "macos")]
pub mod input;
#[cfg(target_os = "macos")]
pub mod capture;
#[cfg(target_os = "macos")]
pub mod browser;
#[cfg(target_os = "macos")]
pub mod focus_steal;
#[cfg(target_os = "macos")]
pub mod permissions;
#[cfg(target_os = "macos")]
pub mod focus_guard;
#[cfg(target_os = "macos")]
pub mod window_change_detector;
#[cfg(target_os = "macos")]
pub mod terminal;
#[cfg(target_os = "macos")]
pub mod event_tap;
#[cfg(target_os = "macos")]
pub mod capture_session;

uniffi::setup_scaffolding!();
