import CoreGraphics
import Foundation

public enum WindowBackgroundCaptureSizer {
    public static func captureSize(
        rawWidth: CGFloat,
        rawHeight: CGFloat,
        maxWidth: Int,
        maxHeight: Int
    ) -> (width: Int, height: Int) {
        let boundedRawWidth = max(1, rawWidth)
        let boundedRawHeight = max(1, rawHeight)
        let boundedMaxWidth = CGFloat(max(1, maxWidth))
        let boundedMaxHeight = CGFloat(max(1, maxHeight))
        let downscale = min(
            1,
            boundedMaxWidth / boundedRawWidth,
            boundedMaxHeight / boundedRawHeight
        )

        return (
            width: max(1, Int((boundedRawWidth * downscale).rounded())),
            height: max(1, Int((boundedRawHeight * downscale).rounded()))
        )
    }
}
