import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

public enum SegmentationQuality: String, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case accurate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        }
    }

    fileprivate var visionQualityLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }
}

public enum SegmentationAnalysisResolution: String, CaseIterable, Identifiable, Sendable {
    case low
    case half
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .half: return "Half"
        case .full: return "Full"
        }
    }

    public func dimensionsTitle(for outputSize: CGSize) -> String {
        let dimensions = pixelDimensions(for: outputSize)
        return "\(dimensions.width)x\(dimensions.height)"
    }

    public func pixelDimensions(for outputSize: CGSize) -> (width: Int, height: Int) {
        switch self {
        case .low:
            return (384, 216)
        case .half:
            return (
                max(1, Int(outputSize.width.rounded()) / 2),
                max(1, Int(outputSize.height.rounded()) / 2)
            )
        case .full:
            return (
                max(1, Int(outputSize.width.rounded())),
                max(1, Int(outputSize.height.rounded()))
            )
        }
    }
}

public enum BackgroundRemovalDefaults {
    private enum Key {
        static let quality = "backgroundRemoval.quality"
        static let analysisResolution = "backgroundRemoval.analysisResolution"
        static let temporalSmoothing = "backgroundRemoval.temporalSmoothing"
        static let maskBlurRadius = "backgroundRemoval.maskBlurRadius"
        static let maskReuseFrameCount = "backgroundRemoval.maskReuseFrameCount"
    }

    public static let defaultQuality: SegmentationQuality = .accurate
    public static let defaultAnalysisResolution: SegmentationAnalysisResolution = .half
    public static let defaultTemporalSmoothing: Double = 0
    public static let defaultMaskBlurRadius: Double = 0.9
    public static let defaultMaskReuseFrameCount = 0

    public static func loadQuality(from defaults: UserDefaults = .standard) -> SegmentationQuality {
        guard let rawValue = defaults.string(forKey: Key.quality),
              let quality = SegmentationQuality(rawValue: rawValue) else {
            return defaultQuality
        }
        return quality
    }

    public static func saveQuality(_ quality: SegmentationQuality, to defaults: UserDefaults = .standard) {
        defaults.set(quality.rawValue, forKey: Key.quality)
    }

    public static func loadAnalysisResolution(
        from defaults: UserDefaults = .standard
    ) -> SegmentationAnalysisResolution {
        guard let rawValue = defaults.string(forKey: Key.analysisResolution),
              let resolution = SegmentationAnalysisResolution(rawValue: rawValue) else {
            return defaultAnalysisResolution
        }
        return resolution
    }

    public static func saveAnalysisResolution(
        _ resolution: SegmentationAnalysisResolution,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(resolution.rawValue, forKey: Key.analysisResolution)
    }

    public static func loadTemporalSmoothing(from defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: Key.temporalSmoothing) as? NSNumber else {
            return defaultTemporalSmoothing
        }
        return clampedTemporalSmoothing(value.doubleValue)
    }

    public static func saveTemporalSmoothing(_ value: Double, to defaults: UserDefaults = .standard) {
        defaults.set(clampedTemporalSmoothing(value), forKey: Key.temporalSmoothing)
    }

    public static func loadMaskBlurRadius(from defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: Key.maskBlurRadius) as? NSNumber else {
            return defaultMaskBlurRadius
        }
        return clampedMaskBlurRadius(value.doubleValue)
    }

    public static func saveMaskBlurRadius(_ value: Double, to defaults: UserDefaults = .standard) {
        defaults.set(clampedMaskBlurRadius(value), forKey: Key.maskBlurRadius)
    }

    public static func loadMaskReuseFrameCount(from defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: Key.maskReuseFrameCount) as? NSNumber else {
            return defaultMaskReuseFrameCount
        }
        return clampedMaskReuseFrameCount(value.intValue)
    }

    public static func saveMaskReuseFrameCount(_ value: Int, to defaults: UserDefaults = .standard) {
        defaults.set(clampedMaskReuseFrameCount(value), forKey: Key.maskReuseFrameCount)
    }

    private static func clampedTemporalSmoothing(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTemporalSmoothing }
        return max(0, min(0.9, value))
    }

    private static func clampedMaskBlurRadius(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMaskBlurRadius }
        return max(0, min(4, value))
    }

    private static func clampedMaskReuseFrameCount(_ value: Int) -> Int {
        max(0, min(5, value))
    }
}

public struct PersonSegmentationConfiguration: Sendable {
    public var quality: SegmentationQuality
    public var analysisResolution: SegmentationAnalysisResolution
    public var temporalSmoothing: Double
    public var maskBlurRadius: Double
    public var outputSize: CGSize

    public init(
        quality: SegmentationQuality,
        analysisResolution: SegmentationAnalysisResolution,
        temporalSmoothing: Double,
        maskBlurRadius: Double,
        outputSize: CGSize
    ) {
        self.quality = quality
        self.analysisResolution = analysisResolution
        self.temporalSmoothing = temporalSmoothing
        self.maskBlurRadius = maskBlurRadius
        self.outputSize = outputSize
    }
}

/// Owns Vision person segmentation, temporal mask smoothing, and render-mask materialization.
public final class PersonBackgroundRemover: @unchecked Sendable {
    public var onError: ((Error) -> Void)?

    private let queue: DispatchQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let request = VNGeneratePersonSegmentationRequest()
    private let stateLock = NSLock()
    private var processing = false
    private var latestMask: CIImage?
    private var latestRenderMask: CIImage?
    private var analysisPool: CVPixelBufferPool?
    private var analysisPoolSize = CGSize.zero
    private var maskPool: CVPixelBufferPool?
    private var maskPoolSize = CGSize.zero
    private var renderMaskPool: CVPixelBufferPool?
    private var renderMaskPoolSize = CGSize.zero

    public init(context: CIContext? = nil, queue: DispatchQueue? = nil) {
        if let context {
            self.context = context
        } else if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.context = CIContext(options: [.cacheIntermediates: false])
        }
        self.queue = queue ?? DispatchQueue(
            label: "BackgroundRemovalKit.segmentation",
            qos: .userInitiated
        )
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    public var hasMask: Bool {
        stateLock.withLock { latestMask != nil }
    }

    public func currentRenderMask() -> CIImage? {
        stateLock.withLock { latestRenderMask }
    }

    /// Schedules a segmentation pass. If one is already running, the new request is dropped.
    @discardableResult
    public func process(
        pixelBuffer: CVPixelBuffer,
        configuration: PersonSegmentationConfiguration
    ) -> Bool {
        let accepted = stateLock.withLock { () -> Bool in
            guard !processing else { return false }
            processing = true
            return true
        }
        guard accepted else { return false }

        queue.async {
            defer {
                self.stateLock.withLock { self.processing = false }
            }
            autoreleasepool {
                do {
                    try self.perform(pixelBuffer: pixelBuffer, configuration: configuration)
                } catch {
                    self.onError?(error)
                }
            }
        }
        return true
    }

    public func refreshRenderMask(outputSize: CGSize, blurRadius: Double) {
        queue.async {
            guard let mask = self.stateLock.withLock({ self.latestMask }) else { return }
            guard let renderMask = self.materializedRenderMask(
                from: mask,
                outputSize: outputSize,
                blurRadius: blurRadius
            ) else { return }

            self.stateLock.withLock {
                if self.latestMask === mask {
                    self.latestRenderMask = renderMask
                }
            }
        }
    }

    public func clear() {
        stateLock.withLock {
            latestMask = nil
            latestRenderMask = nil
        }
    }

    public func resetResources() {
        queue.async {
            self.analysisPool = nil
            self.analysisPoolSize = .zero
            self.renderMaskPool = nil
            self.renderMaskPoolSize = .zero
        }
    }

    private func perform(
        pixelBuffer: CVPixelBuffer,
        configuration: PersonSegmentationConfiguration
    ) throws {
        let dimensions = configuration.analysisResolution.pixelDimensions(for: configuration.outputSize)
        let analysisSize = CGSize(width: dimensions.width, height: dimensions.height)
        guard let analysisBuffer = makeAnalysisBuffer(size: analysisSize) else { return }

        context.render(
            aspectFillImage(from: pixelBuffer, targetSize: analysisSize),
            to: analysisBuffer,
            bounds: CGRect(origin: .zero, size: analysisSize),
            colorSpace: colorSpace
        )

        request.qualityLevel = configuration.quality.visionQualityLevel
        let handler = VNImageRequestHandler(cvPixelBuffer: analysisBuffer, orientation: .up)
        try handler.perform([request])
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return }

        var newMask = normalized(CIImage(cvPixelBuffer: maskBuffer))
        if let previousMask = stateLock.withLock({ latestMask }), previousMask.extent.size == newMask.extent.size {
            let weight = max(0.08, min(1, 1 - configuration.temporalSmoothing))
            newMask = newMask.applyingFilter("CIMix", parameters: [
                kCIInputBackgroundImageKey: previousMask,
                kCIInputAmountKey: weight
            ])
        }

        guard let materializedMask = materializedMask(from: newMask),
              let renderMask = materializedRenderMask(
                from: materializedMask,
                outputSize: configuration.outputSize,
                blurRadius: configuration.maskBlurRadius
              ) else { return }

        stateLock.withLock {
            latestMask = materializedMask
            latestRenderMask = renderMask
        }
    }

    private func aspectFillImage(from pixelBuffer: CVPixelBuffer, targetSize: CGSize) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = max(targetSize.width / image.extent.width, targetSize.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: (scaled.extent.width - targetSize.width) * 0.5,
            y: (scaled.extent.height - targetSize.height) * 0.5,
            width: targetSize.width,
            height: targetSize.height
        )
        return scaled.cropped(to: crop).transformed(
            by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y)
        )
    }

    private func materializedMask(from mask: CIImage) -> CIImage? {
        let mask = normalized(mask)
        guard let pixelBuffer = makeMaskBuffer(size: mask.extent.size) else { return nil }
        context.render(mask, to: pixelBuffer, bounds: mask.extent, colorSpace: nil)
        return CIImage(cvPixelBuffer: pixelBuffer)
    }

    private func materializedRenderMask(
        from mask: CIImage,
        outputSize: CGSize,
        blurRadius: Double
    ) -> CIImage? {
        let extent = CGRect(origin: .zero, size: outputSize)
        guard let pixelBuffer = makeRenderMaskBuffer(size: outputSize) else { return nil }
        context.render(
            upscaled(mask: mask, to: extent, blurRadius: blurRadius),
            to: pixelBuffer,
            bounds: extent,
            colorSpace: nil
        )
        return CIImage(cvPixelBuffer: pixelBuffer)
    }

    private func upscaled(mask: CIImage, to extent: CGRect, blurRadius: Double) -> CIImage {
        let mask = normalized(mask)
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / mask.extent.width,
            y: extent.height / mask.extent.height
        ))
        guard blurRadius > 0 else { return scaled.cropped(to: extent) }
        return scaled
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
    }

    private func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
    }

    private func makeAnalysisBuffer(size: CGSize) -> CVPixelBuffer? {
        if analysisPool == nil || analysisPoolSize != size {
            analysisPool = Self.makePool(
                width: Int(size.width),
                height: Int(size.height),
                pixelFormat: kCVPixelFormatType_32BGRA
            )
            analysisPoolSize = size
        }
        return Self.makeBuffer(from: analysisPool)
    }

    private func makeMaskBuffer(size: CGSize) -> CVPixelBuffer? {
        if maskPool == nil || maskPoolSize != size {
            maskPool = Self.makePool(
                width: Int(size.width.rounded()),
                height: Int(size.height.rounded()),
                pixelFormat: kCVPixelFormatType_OneComponent8,
                bitmapCompatible: false
            )
            maskPoolSize = size
        }
        return Self.makeBuffer(from: maskPool)
    }

    private func makeRenderMaskBuffer(size: CGSize) -> CVPixelBuffer? {
        if renderMaskPool == nil || renderMaskPoolSize != size {
            renderMaskPool = Self.makePool(
                width: Int(size.width.rounded()),
                height: Int(size.height.rounded()),
                pixelFormat: kCVPixelFormatType_OneComponent8,
                bitmapCompatible: false
            )
            renderMaskPoolSize = size
        }
        return Self.makeBuffer(from: renderMaskPool)
    }

    private static func makeBuffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private static func makePool(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        bitmapCompatible: Bool = true
    ) -> CVPixelBufferPool? {
        guard width > 0, height > 0 else { return nil }
        var attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        if bitmapCompatible {
            attributes[kCVPixelBufferCGImageCompatibilityKey as String] = true
            attributes[kCVPixelBufferCGBitmapContextCompatibilityKey as String] = true
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
