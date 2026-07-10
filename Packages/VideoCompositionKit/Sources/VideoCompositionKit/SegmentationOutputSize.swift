import BackgroundRemovalKit
import CoreGraphics
import SharedFrameKit

public extension SegmentationAnalysisResolution {
    func dimensionsTitle(for outputFrameSize: OutputFrameSize) -> String {
        dimensionsTitle(for: CGSize(width: outputFrameSize.width, height: outputFrameSize.height))
    }
}
