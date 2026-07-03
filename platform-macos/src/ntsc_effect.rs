use ntsc_rs::{
    settings::{
        ChromaLowpass, FbmNoiseSettings, HeadSwitchingMidLineSettings, HeadSwitchingSettings,
        LumaLowpass, RingingSettings, TrackingNoiseSettings, UseField, VHSEdgeWaveSettings,
        VHSSettings, VHSSharpenSettings, VHSTapeSpeed,
    },
    yiq_fielding::Bgrx,
    NtscEffect,
};

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum NtscEffectPreset {
    Low,
    Medium,
    Hard,
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NtscEffectInPlaceStatus {
    Ok = 0,
    NullBuffer = 1,
    InvalidDimensions = 2,
    InvalidBufferLength = 3,
    InvalidPreset = 4,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NtscEffectError {
    #[error("Invalid NTSC frame dimensions: {width}x{height}")]
    InvalidDimensions { width: u32, height: u32 },
    #[error("Expected {expected} BGRX bytes for {width}x{height}, got {actual}")]
    InvalidBufferLength {
        width: u32,
        height: u32,
        expected: u64,
        actual: u64,
    },
}

#[uniffi::export]
pub fn apply_ntsc_effect_bgrx(
    width: u32,
    height: u32,
    frame_num: u64,
    preset: NtscEffectPreset,
    mut pixels: Vec<u8>,
) -> Result<Vec<u8>, NtscEffectError> {
    if width == 0 || height == 0 {
        return Err(NtscEffectError::InvalidDimensions { width, height });
    }

    let expected = u64::from(width) * u64::from(height) * 4;
    if pixels.len() as u64 != expected {
        return Err(NtscEffectError::InvalidBufferLength {
            width,
            height,
            expected,
            actual: pixels.len() as u64,
        });
    }

    effect_for_preset(preset).apply_effect_to_buffer::<Bgrx, u8>(
        (width as usize, height as usize),
        &mut pixels,
        frame_num as usize,
        [1.0, 1.0],
    );

    Ok(pixels)
}

#[no_mangle]
pub unsafe extern "C" fn platform_macos_apply_ntsc_effect_bgrx_in_place(
    width: u32,
    height: u32,
    frame_num: u64,
    preset: u32,
    pixels: *mut u8,
    pixel_len: u64,
) -> i32 {
    apply_ntsc_effect_bgrx_in_place(width, height, frame_num, preset, pixels, pixel_len) as i32
}

unsafe fn apply_ntsc_effect_bgrx_in_place(
    width: u32,
    height: u32,
    frame_num: u64,
    preset: u32,
    pixels: *mut u8,
    pixel_len: u64,
) -> NtscEffectInPlaceStatus {
    if width == 0 || height == 0 {
        return NtscEffectInPlaceStatus::InvalidDimensions;
    }

    if pixels.is_null() {
        return NtscEffectInPlaceStatus::NullBuffer;
    }

    let expected = u64::from(width) * u64::from(height) * 4;
    if pixel_len != expected {
        return NtscEffectInPlaceStatus::InvalidBufferLength;
    }

    let Some(preset) = preset_from_ffi(preset) else {
        return NtscEffectInPlaceStatus::InvalidPreset;
    };

    let pixels = std::slice::from_raw_parts_mut(pixels, expected as usize);
    effect_for_preset(preset).apply_effect_to_buffer::<Bgrx, u8>(
        (width as usize, height as usize),
        pixels,
        frame_num as usize,
        [1.0, 1.0],
    );

    NtscEffectInPlaceStatus::Ok
}

fn preset_from_ffi(preset: u32) -> Option<NtscEffectPreset> {
    match preset {
        0 => Some(NtscEffectPreset::Low),
        1 => Some(NtscEffectPreset::Medium),
        2 => Some(NtscEffectPreset::Hard),
        _ => None,
    }
}

fn effect_for_preset(preset: NtscEffectPreset) -> NtscEffect {
    match preset {
        NtscEffectPreset::Low => NtscEffect::default(),
        NtscEffectPreset::Medium => medium_effect(),
        NtscEffectPreset::Hard => hard_effect(),
    }
}

fn medium_effect() -> NtscEffect {
    let mut effect = NtscEffect::default();
    effect.luma_smear = 0.95;
    effect.composite_sharpening = 1.35;
    effect.head_switching = Some(HeadSwitchingSettings {
        height: 14,
        offset: 4,
        horiz_shift: 104.0,
        mid_line: Some(HeadSwitchingMidLineSettings {
            position: 0.8,
            jitter: 0.12,
        }),
    });
    effect.tracking_noise = Some(TrackingNoiseSettings {
        height: 18,
        wave_intensity: 28.0,
        snow_intensity: 0.08,
        snow_anisotropy: 0.35,
        noise_intensity: 0.45,
    });
    effect.ringing = Some(RingingSettings {
        frequency: 0.38,
        power: 3.0,
        intensity: 6.5,
    });
    effect.composite_noise = Some(FbmNoiseSettings {
        frequency: 0.7,
        intensity: 0.1,
        detail: 2,
    });
    effect.luma_noise = Some(FbmNoiseSettings {
        frequency: 0.55,
        intensity: 0.025,
        detail: 2,
    });
    effect.chroma_noise = Some(FbmNoiseSettings {
        frequency: 0.08,
        intensity: 0.22,
        detail: 3,
    });
    effect.snow_intensity = 0.0012;
    effect.chroma_phase_noise_intensity = 0.004;
    effect.chroma_phase_error = 0.02;
    effect.chroma_delay_horizontal = 2.0;
    effect.chroma_delay_vertical = 1;
    effect.vhs_settings = Some(VHSSettings {
        tape_speed: VHSTapeSpeed::EP,
        chroma_loss: 0.0002,
        sharpen: Some(VHSSharpenSettings {
            intensity: 0.45,
            frequency: 0.65,
        }),
        edge_wave: Some(VHSEdgeWaveSettings {
            intensity: 1.2,
            speed: 8.0,
            frequency: 0.12,
            detail: 3,
        }),
    });
    effect
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_place_rejects_invalid_dimensions() {
        let mut pixels = [0_u8; 4];
        let status = unsafe {
            apply_ntsc_effect_bgrx_in_place(0, 1, 0, 0, pixels.as_mut_ptr(), pixels.len() as u64)
        };

        assert_eq!(status, NtscEffectInPlaceStatus::InvalidDimensions);
    }

    #[test]
    fn in_place_rejects_null_buffer() {
        let status =
            unsafe { apply_ntsc_effect_bgrx_in_place(1, 1, 0, 0, std::ptr::null_mut(), 4) };

        assert_eq!(status, NtscEffectInPlaceStatus::NullBuffer);
    }

    #[test]
    fn in_place_rejects_invalid_buffer_length() {
        let mut pixels = [0_u8; 3];
        let status = unsafe {
            apply_ntsc_effect_bgrx_in_place(1, 1, 0, 0, pixels.as_mut_ptr(), pixels.len() as u64)
        };

        assert_eq!(status, NtscEffectInPlaceStatus::InvalidBufferLength);
    }

    #[test]
    fn in_place_rejects_invalid_preset() {
        let mut pixels = [0_u8; 4];
        let status = unsafe {
            apply_ntsc_effect_bgrx_in_place(1, 1, 0, 99, pixels.as_mut_ptr(), pixels.len() as u64)
        };

        assert_eq!(status, NtscEffectInPlaceStatus::InvalidPreset);
    }
}

fn hard_effect() -> NtscEffect {
    let mut effect = NtscEffect::default();
    effect.use_field = UseField::InterleavedUpper;
    effect.input_luma_filter = LumaLowpass::Box;
    effect.chroma_lowpass_in = ChromaLowpass::Light;
    effect.chroma_lowpass_out = ChromaLowpass::Light;
    effect.luma_smear = 1.375;
    effect.composite_sharpening = 1.675;
    effect.head_switching = Some(HeadSwitchingSettings {
        height: 22,
        offset: 6,
        horiz_shift: 162.0,
        mid_line: Some(HeadSwitchingMidLineSettings {
            position: 0.76,
            jitter: 0.2,
        }),
    });
    effect.tracking_noise = Some(TrackingNoiseSettings {
        height: 26,
        wave_intensity: 49.0,
        snow_intensity: 0.16,
        snow_anisotropy: 0.55,
        noise_intensity: 0.7,
    });
    effect.ringing = Some(RingingSettings {
        frequency: 0.35,
        power: 3.9,
        intensity: 10.75,
    });
    effect.composite_noise = Some(FbmNoiseSettings {
        frequency: 0.9,
        intensity: 0.16,
        detail: 3,
    });
    effect.luma_noise = Some(FbmNoiseSettings {
        frequency: 0.7,
        intensity: 0.0525,
        detail: 3,
    });
    effect.chroma_noise = Some(FbmNoiseSettings {
        frequency: 0.105,
        intensity: 0.35,
        detail: 4,
    });
    effect.snow_intensity = 0.0056;
    effect.snow_anisotropy = 0.725;
    effect.chroma_phase_noise_intensity = 0.0145;
    effect.chroma_phase_error = 0.05;
    effect.chroma_delay_horizontal = 4.0;
    effect.chroma_delay_vertical = 2;
    effect.vhs_settings = Some(VHSSettings {
        tape_speed: VHSTapeSpeed::EP,
        chroma_loss: 0.0011,
        sharpen: Some(VHSSharpenSettings {
            intensity: 0.65,
            frequency: 0.775,
        }),
        edge_wave: Some(VHSEdgeWaveSettings {
            intensity: 2.6,
            speed: 11.0,
            frequency: 0.17,
            detail: 4,
        }),
    });
    effect
}
