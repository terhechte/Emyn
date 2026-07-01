//! Window / display screenshot using the macOS `screencapture` CLI tool.
//!
//! `screencapture -l <windowID> -x -o <file>` captures a single window by
//! CGWindowID to a PNG without any screen-recording permission dialog.
//!
//! `screencapture -x <file>` captures the full main display.
//!
//! For production use, the ImageIO/CGWindowListCreateImageFromArray path
//! would give lower overhead (no subprocess + temp file), but the subprocess
//! approach is simpler to implement correctly and is reliable across OS versions.

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use std::process::Command;

/// Capture a window by its `window_id` (CGWindowID).
/// Returns raw PNG bytes or an error.
pub fn screenshot_window_bytes(window_id: u32) -> anyhow::Result<Vec<u8>> {
    let tmp_path = format!("/tmp/cua-driver-rs-capture-{}.png", window_id);

    let status = Command::new("screencapture")
        .args([
            "-l", &window_id.to_string(),
            "-x",  // no sound
            "-o",  // no shadow
            &tmp_path,
        ])
        .status()?;

    if !status.success() {
        anyhow::bail!("screencapture failed for window {window_id}");
    }

    let bytes = std::fs::read(&tmp_path)?;
    let _ = std::fs::remove_file(&tmp_path);

    if bytes.is_empty() {
        anyhow::bail!("screencapture produced empty output for window {window_id}");
    }
    Ok(bytes)
}

/// Capture a window by its `window_id` (CGWindowID).
/// Returns (base64-encoded PNG, width, height) or an error.
pub fn screenshot_window(window_id: u32) -> anyhow::Result<(String, u32, u32)> {
    let bytes = screenshot_window_bytes(window_id)?;
    let (w, h) = png_dimensions(&bytes)?;
    let b64 = BASE64.encode(&bytes);
    Ok((b64, w, h))
}

/// Capture the full main display.
/// Returns raw PNG bytes or an error.
pub fn screenshot_display_bytes() -> anyhow::Result<Vec<u8>> {
    // Use a pid-unique path so concurrent cua-driver processes don't step on each other.
    let tmp_path = format!("/tmp/cua-driver-rs-display-{}.png", std::process::id());

    let status = Command::new("screencapture")
        .args(["-x", &*tmp_path])
        .status()?;

    if !status.success() {
        anyhow::bail!("screencapture failed for main display");
    }

    let bytes = std::fs::read(&tmp_path)?;
    let _ = std::fs::remove_file(&tmp_path);

    if bytes.is_empty() {
        anyhow::bail!("screencapture produced empty output for main display");
    }
    Ok(bytes)
}

/// Capture the main display and return (base64-encoded PNG, width, height).
pub fn screenshot_display() -> anyhow::Result<(String, u32, u32)> {
    let bytes = screenshot_display_bytes()?;
    let (w, h) = png_dimensions(&bytes)?;
    let b64 = BASE64.encode(&bytes);
    Ok((b64, w, h))
}

/// Parse width and height from a PNG file's IHDR chunk.
pub fn png_dimensions(data: &[u8]) -> anyhow::Result<(u32, u32)> {
    if data.len() < 24 || &data[1..4] != b"PNG" {
        anyhow::bail!("not a PNG");
    }
    let w = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
    let h = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
    Ok((w, h))
}
