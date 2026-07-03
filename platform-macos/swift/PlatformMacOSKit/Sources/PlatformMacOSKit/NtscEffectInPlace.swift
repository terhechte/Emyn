import Foundation

#if canImport(platform_macosFFI)
import platform_macosFFI
#endif

public enum NtscEffectInPlaceError: LocalizedError {
    case nullBuffer
    case invalidDimensions
    case invalidBufferLength
    case invalidPreset
    case unknownStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .nullBuffer:
            return "NTSC effect received a null pixel buffer."
        case .invalidDimensions:
            return "NTSC effect received invalid frame dimensions."
        case .invalidBufferLength:
            return "NTSC effect received an invalid pixel buffer length."
        case .invalidPreset:
            return "NTSC effect received an invalid preset."
        case .unknownStatus(let status):
            return "NTSC effect failed with status \(status)."
        }
    }
}

public func applyNtscEffectBgrxInPlace(
    width: UInt32,
    height: UInt32,
    frameNum: UInt64,
    preset: NtscEffectPreset,
    pixels: UnsafeMutableRawPointer,
    byteCount: Int
) throws {
    let status = platform_macos_apply_ntsc_effect_bgrx_in_place(
        width,
        height,
        frameNum,
        preset.cABIValue,
        pixels.assumingMemoryBound(to: UInt8.self),
        UInt64(byteCount)
    )

    switch status {
    case 0:
        return
    case 1:
        throw NtscEffectInPlaceError.nullBuffer
    case 2:
        throw NtscEffectInPlaceError.invalidDimensions
    case 3:
        throw NtscEffectInPlaceError.invalidBufferLength
    case 4:
        throw NtscEffectInPlaceError.invalidPreset
    default:
        throw NtscEffectInPlaceError.unknownStatus(status)
    }
}

private extension NtscEffectPreset {
    var cABIValue: UInt32 {
        switch self {
        case .low:
            return 0
        case .medium:
            return 1
        case .hard:
            return 2
        }
    }
}
