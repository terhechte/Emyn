import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import ScreenCaptureKit
import Vision

struct CameraDeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
}

enum SegmentationQuality: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        }
    }

    var visionQualityLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }
}

enum SegmentationAnalysisResolution: String, CaseIterable, Identifiable {
    case low
    case half
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .half: return "Half"
        case .full: return "Full"
        }
    }

    var dimensionsTitle: String {
        let dimensions = pixelDimensions
        return "\(dimensions.width)x\(dimensions.height)"
    }

    var pixelDimensions: (width: Int, height: Int) {
        switch self {
        case .low:
            return (384, 216)
        case .half:
            return (SharedFrameConfiguration.width / 2, SharedFrameConfiguration.height / 2)
        case .full:
            return (SharedFrameConfiguration.width, SharedFrameConfiguration.height)
        }
    }
}

enum BackgroundMode: String, CaseIterable, Identifiable {
    case replacement
    case blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replacement: return "Replace"
        case .blur: return "Blur"
        }
    }
}

enum BackgroundPreset: String, CaseIterable, Identifiable {
    case black
    case white
    case green
    case blue
    case transparent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .green: return "Green"
        case .blue: return "Blue"
        case .transparent: return "Transparent"
        }
    }

    var rgba: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        switch self {
        case .black:
            return (0.02, 0.02, 0.025, 1.0)
        case .white:
            return (0.92, 0.93, 0.94, 1.0)
        case .green:
            return (0.0, 0.75, 0.32, 1.0)
        case .blue:
            return (0.05, 0.18, 0.62, 1.0)
        case .transparent:
            return (0.0, 0.0, 0.0, 0.0)
        }
    }

    var nsColor: NSColor {
        let value = rgba
        return NSColor(
            calibratedRed: value.red,
            green: value.green,
            blue: value.blue,
            alpha: max(value.alpha, 0.18)
        )
    }
}

private struct ProcessingSettings {
    var quality: SegmentationQuality = .balanced
    var analysisResolution: SegmentationAnalysisResolution = .half
    var temporalSmoothing: Double = 0.72
    var maskReuseFrameCount: Int = 2
    var backgroundMode: BackgroundMode = .replacement
    var backgroundBlurRadius: Double = 18
    var background: BackgroundPreset = .black
}

final class CameraPipeline: NSObject, ObservableObject {
    @Published private(set) var cameras: [CameraDeviceInfo] = []
    @Published var selectedCameraID: String = "" {
        didSet {
            guard oldValue != selectedCameraID, isRunning else { return }
            restart()
        }
    }

    @Published var quality: SegmentationQuality = .balanced {
        didSet {
            updateSettings { $0.quality = self.quality }
            segmentationQueue.async { [quality] in
                self.segmentationRequest.qualityLevel = quality.visionQualityLevel
            }
        }
    }

    @Published var analysisResolution: SegmentationAnalysisResolution = .half {
        didSet {
            updateSettings { $0.analysisResolution = self.analysisResolution }
            clearMask()
        }
    }

    @Published var temporalSmoothing: Double = 0.72 {
        didSet { updateSettings { $0.temporalSmoothing = self.temporalSmoothing } }
    }

    @Published var maskReuseFrameCount: Int = 2 {
        didSet { updateSettings { $0.maskReuseFrameCount = self.maskReuseFrameCount } }
    }

    @Published var backgroundMode: BackgroundMode = .replacement {
        didSet { updateSettings { $0.backgroundMode = self.backgroundMode } }
    }

    @Published var backgroundBlurRadius: Double = 18 {
        didSet { updateSettings { $0.backgroundBlurRadius = self.backgroundBlurRadius } }
    }

    @Published var backgroundPreset: BackgroundPreset = .black {
        didSet { updateSettings { $0.background = self.backgroundPreset } }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var measuredFramesPerSecond: Double = 0
    @Published private(set) var selectedWindowBackgroundTitle: String?
    @Published private(set) var windowBackgroundStatusText = "Color background"

    var previewHandler: ((CMSampleBuffer) -> Void)?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.stylemac.Emyn.capture", qos: .userInitiated)
    private let segmentationQueue = DispatchQueue(label: "com.stylemac.Emyn.segmentation", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "com.stylemac.Emyn.render", qos: .userInteractive)
    private let settingsQueue = DispatchQueue(label: "com.stylemac.Emyn.settings")
    private let screenCaptureQueue = DispatchQueue(label: "com.stylemac.Emyn.screen-capture", qos: .userInitiated)
    private let maskLock = NSLock()
    private let renderLock = NSLock()
    private let segmentationStateLock = NSLock()
    private let backgroundLock = NSLock()

    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let segmentationRequest = VNGeneratePersonSegmentationRequest()
    private let frameWriter: SharedFrameWriter?
    private static let screenCaptureBackgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    private var settings = ProcessingSettings()
    private var latestMask: CIImage?
    private var outputPixelBufferPool: CVPixelBufferPool?
    private var analysisPixelBufferPool: CVPixelBufferPool?
    private var analysisPixelBufferPoolSize = CGSize(width: 0, height: 0)
    private var outputFormatDescription: CMFormatDescription?
    private var frameCounter: UInt64 = 0
    private var segmentationInFlight = false
    private var renderInFlight = false
    private var renderedFrameCounter = 0
    private var lastFPSUpdate = CACurrentMediaTime()
    private var windowBackgroundStream: SCStream?
    private var latestWindowBackgroundPixelBuffer: CVPixelBuffer?

    override init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(
                mtlDevice: metalDevice,
                options: [.cacheIntermediates: false]
            )
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }

        frameWriter = try? SharedFrameWriter()

        super.init()

        segmentationRequest.qualityLevel = quality.visionQualityLevel
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        outputPixelBufferPool = Self.makePixelBufferPool(
            width: SharedFrameConfiguration.width,
            height: SharedFrameConfiguration.height,
            pixelFormat: SharedFrameConfiguration.pixelFormat
        )
        let analysisDimensions = analysisResolution.pixelDimensions
        analysisPixelBufferPool = Self.makePixelBufferPool(
            width: analysisDimensions.width,
            height: analysisDimensions.height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        analysisPixelBufferPoolSize = CGSize(width: analysisDimensions.width, height: analysisDimensions.height)

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: SharedFrameConfiguration.pixelFormat,
            width: Int32(SharedFrameConfiguration.width),
            height: Int32(SharedFrameConfiguration.height),
            extensions: nil,
            formatDescriptionOut: &outputFormatDescription
        )

        refreshCameras()
        if frameWriter == nil {
            statusText = "Shared frame output unavailable"
        }
    }

    func refreshCameras() {
        let devices = Self.discoverCameraDevices()
        let infos = devices.map {
            CameraDeviceInfo(id: $0.uniqueID, name: $0.localizedName, detail: $0.deviceType.rawValue)
        }

        DispatchQueue.main.async {
            self.cameras = infos
            if self.selectedCameraID.isEmpty || !infos.contains(where: { $0.id == self.selectedCameraID }) {
                self.selectedCameraID = infos.first?.id ?? ""
            }
        }
    }

    func start() {
        refreshCameras()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartCapture()
        case .notDetermined:
            setStatus("Waiting for camera access")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStartCapture()
                } else {
                    self.setStatus("Camera access denied")
                }
            }
        case .denied, .restricted:
            setStatus("Camera access denied")
        @unknown default:
            setStatus("Camera access unavailable")
        }
    }

    func stop() {
        captureQueue.async {
            self.captureSession.stopRunning()
            self.captureSession.beginConfiguration()
            self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }
            self.captureSession.commitConfiguration()

            DispatchQueue.main.async {
                self.isRunning = false
                self.statusText = "Stopped"
            }
        }
    }

    func selectWindowBackground(_ option: WindowBackgroundOption) {
        selectedWindowBackgroundTitle = option.displayTitle
        windowBackgroundStatusText = "Starting window background"
        startWindowBackgroundCapture(window: option.window, title: option.displayTitle)
    }

    func clearWindowBackground() {
        selectedWindowBackgroundTitle = nil
        windowBackgroundStatusText = "Color background"
        clearLatestWindowBackgroundPixelBuffer()

        screenCaptureQueue.async {
            self.stopWindowBackgroundStream()
        }
    }

    func restart() {
        stop()
        captureQueue.asyncAfter(deadline: .now() + 0.25) {
            self.configureAndStartCapture()
        }
    }

    private func configureAndStartCapture() {
        let cameraID = selectedCameraID
        captureQueue.async {
            guard let device = Self.discoverCameraDevices().first(where: { $0.uniqueID == cameraID })
                    ?? Self.discoverCameraDevices().first else {
                self.setStatus("No camera found")
                return
            }

            do {
                self.captureSession.beginConfiguration()
                self.captureSession.sessionPreset = .hd1280x720
                self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
                self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }

                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else {
                    self.captureSession.commitConfiguration()
                    self.setStatus("Camera input unavailable")
                    return
                }

                self.captureSession.addInput(input)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: SharedFrameConfiguration.pixelFormat
                ]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.captureQueue)

                guard self.captureSession.canAddOutput(self.videoOutput) else {
                    self.captureSession.commitConfiguration()
                    self.setStatus("Video output unavailable")
                    return
                }

                self.captureSession.addOutput(self.videoOutput)
                self.captureSession.commitConfiguration()
                self.captureSession.startRunning()

                self.clearMask()
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.statusText = "Running"
                }
            } catch {
                self.captureSession.commitConfiguration()
                self.setStatus(error.localizedDescription)
            }
        }
    }

    private static func discoverCameraDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices.filter { $0.localizedName != SharedFrameConfiguration.virtualCameraName }
    }

    private func scheduleSegmentation(for pixelBuffer: CVPixelBuffer) {
        guard beginSegmentationIfPossible() else { return }

        segmentationQueue.async {
            defer { self.finishSegmentation() }
            self.performSegmentation(on: pixelBuffer)
        }
    }

    private func performSegmentation(on pixelBuffer: CVPixelBuffer) {
        let settings = currentSettings()
        let analysisDimensions = settings.analysisResolution.pixelDimensions
        let analysisSize = CGSize(width: analysisDimensions.width, height: analysisDimensions.height)

        guard let analysisPixelBuffer = makeAnalysisPixelBuffer(size: analysisSize) else {
            return
        }

        let analysisImage = aspectFillImage(from: pixelBuffer, targetSize: analysisSize)
        ciContext.render(
            analysisImage,
            to: analysisPixelBuffer,
            bounds: CGRect(origin: .zero, size: analysisSize),
            colorSpace: colorSpace
        )

        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: analysisPixelBuffer, orientation: .up)
            try handler.perform([segmentationRequest])
            guard let maskPixelBuffer = segmentationRequest.results?.first?.pixelBuffer else {
                return
            }

            var newMask = CIImage(cvPixelBuffer: maskPixelBuffer)
            newMask = normalizeExtent(newMask)

            if let previousMask = currentMask(), previousMask.extent.size == newMask.extent.size {
                let newWeight = max(0.08, min(1.0, 1.0 - settings.temporalSmoothing))
                newMask = newMask.applyingFilter("CIMix", parameters: [
                    kCIInputBackgroundImageKey: previousMask,
                    kCIInputAmountKey: newWeight
                ])
            }

            setCurrentMask(newMask)
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    private func scheduleRender(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        renderLock.lock()
        guard !renderInFlight else {
            renderLock.unlock()
            return
        }
        renderInFlight = true
        renderLock.unlock()

        renderQueue.async {
            self.render(pixelBuffer: pixelBuffer, timestamp: timestamp)
            self.renderLock.lock()
            self.renderInFlight = false
            self.renderLock.unlock()
        }
    }

    private func render(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let outputPixelBuffer = makeOutputPixelBuffer() else {
            return
        }

        let outputSize = CGSize(
            width: SharedFrameConfiguration.width,
            height: SharedFrameConfiguration.height
        )
        let outputExtent = CGRect(origin: .zero, size: outputSize)
        let foreground = aspectFillImage(from: pixelBuffer, targetSize: outputSize)
        let settings = currentSettings()

        let renderedImage: CIImage
        if let mask = currentMask() {
            let upscaledMask = upscale(mask: mask, to: outputExtent)
            let background = backgroundImage(
                settings: settings,
                foreground: foreground,
                outputExtent: outputExtent
            )

            renderedImage = foreground.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: upscaledMask
            ])
            .cropped(to: outputExtent)
        } else {
            renderedImage = foreground.cropped(to: outputExtent)
        }

        ciContext.render(
            renderedImage,
            to: outputPixelBuffer,
            bounds: outputExtent,
            colorSpace: colorSpace
        )

        frameWriter?.publish(pixelBuffer: outputPixelBuffer, presentationTime: timestamp)
        if let sampleBuffer = makeSampleBuffer(from: outputPixelBuffer, timestamp: timestamp) {
            DispatchQueue.main.async {
                self.previewHandler?(sampleBuffer)
            }
        }
        updateMeasuredFPS()
    }

    private func aspectFillImage(from pixelBuffer: CVPixelBuffer, targetSize: CGSize) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let scale = max(targetSize.width / extent.width, targetSize.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: (scaled.extent.width - targetSize.width) * 0.5,
            y: (scaled.extent.height - targetSize.height) * 0.5,
            width: targetSize.width,
            height: targetSize.height
        )

        return scaled
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
    }

    private func backgroundImage(settings: ProcessingSettings, foreground: CIImage, outputExtent: CGRect) -> CIImage {
        if settings.backgroundMode == .blur {
            let radius = max(0, settings.backgroundBlurRadius)
            return foreground
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: outputExtent)
        }

        if let pixelBuffer = currentWindowBackgroundPixelBuffer() {
            return aspectFillImage(from: pixelBuffer, targetSize: outputExtent.size)
                .cropped(to: outputExtent)
        }

        let color = settings.background.rgba
        return CIImage(color: CIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        ))
        .cropped(to: outputExtent)
    }

    private func upscale(mask: CIImage, to extent: CGRect) -> CIImage {
        let normalizedMask = normalizeExtent(mask)
        let scaleX = extent.width / normalizedMask.extent.width
        let scaleY = extent.height / normalizedMask.extent.height

        return normalizedMask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.9])
            .cropped(to: extent)
    }

    private func normalizeExtent(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
    }

    private func makeOutputPixelBuffer() -> CVPixelBuffer? {
        guard let outputPixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool, &pixelBuffer)
        return pixelBuffer
    }

    private func makeAnalysisPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if analysisPixelBufferPool == nil || analysisPixelBufferPoolSize != size {
            analysisPixelBufferPool = Self.makePixelBufferPool(
                width: Int(size.width),
                height: Int(size.height),
                pixelFormat: kCVPixelFormatType_32BGRA
            )
            analysisPixelBufferPoolSize = size
        }

        guard let analysisPixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, analysisPixelBufferPool, &pixelBuffer)
        return pixelBuffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        guard let outputFormatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: timestamp.isValid ? timestamp : CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: outputFormatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    private static func makePixelBufferPool(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private func currentSettings() -> ProcessingSettings {
        settingsQueue.sync { settings }
    }

    private func updateSettings(_ update: @escaping (inout ProcessingSettings) -> Void) {
        settingsQueue.async {
            update(&self.settings)
        }
    }

    private func currentMask() -> CIImage? {
        maskLock.lock()
        defer { maskLock.unlock() }
        return latestMask
    }

    private func setCurrentMask(_ mask: CIImage) {
        maskLock.lock()
        latestMask = mask
        maskLock.unlock()
    }

    private func clearMask() {
        maskLock.lock()
        latestMask = nil
        maskLock.unlock()
    }

    private func currentWindowBackgroundPixelBuffer() -> CVPixelBuffer? {
        backgroundLock.lock()
        defer { backgroundLock.unlock() }
        return latestWindowBackgroundPixelBuffer
    }

    private func setLatestWindowBackgroundPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        backgroundLock.lock()
        latestWindowBackgroundPixelBuffer = pixelBuffer
        backgroundLock.unlock()
    }

    private func clearLatestWindowBackgroundPixelBuffer() {
        backgroundLock.lock()
        latestWindowBackgroundPixelBuffer = nil
        backgroundLock.unlock()
    }

    private func startWindowBackgroundCapture(window: SCWindow, title: String) {
        screenCaptureQueue.async {
            self.stopWindowBackgroundStream()
            self.clearLatestWindowBackgroundPixelBuffer()

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = Self.makeWindowBackgroundStreamConfiguration(for: window.frame)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.screenCaptureQueue)
                self.windowBackgroundStream = stream
                stream.startCapture { error in
                    self.screenCaptureQueue.async {
                        guard self.windowBackgroundStream === stream else { return }

                        if let error {
                            self.windowBackgroundStream = nil
                            self.clearLatestWindowBackgroundPixelBuffer()
                            DispatchQueue.main.async {
                                self.selectedWindowBackgroundTitle = nil
                                self.windowBackgroundStatusText = error.localizedDescription
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.selectedWindowBackgroundTitle = title
                                self.windowBackgroundStatusText = "Using \(title)"
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.windowBackgroundStatusText = error.localizedDescription
                }
            }
        }
    }

    private func stopWindowBackgroundStream() {
        guard let stream = windowBackgroundStream else {
            return
        }

        windowBackgroundStream = nil
        stream.stopCapture { _ in }
    }

    private static func makeWindowBackgroundStreamConfiguration(for frame: CGRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let captureSize = windowBackgroundCaptureSize(for: frame)
        configuration.width = captureSize.width
        configuration.height = captureSize.height
        configuration.pixelFormat = SharedFrameConfiguration.pixelFormat
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        configuration.backgroundColor = screenCaptureBackgroundColor
        return configuration
    }

    private static func windowBackgroundCaptureSize(for frame: CGRect) -> (width: Int, height: Int) {
        let scale = backingScaleFactor(for: frame)
        let rawWidth = max(1, frame.width * scale)
        let rawHeight = max(1, frame.height * scale)
        let maxDimension: CGFloat = 2560
        let downscale = min(1, maxDimension / max(rawWidth, rawHeight))

        return (
            width: max(1, Int((rawWidth * downscale).rounded())),
            height: max(1, Int((rawHeight * downscale).rounded()))
        )
    }

    private static func backingScaleFactor(for frame: CGRect) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func beginSegmentationIfPossible() -> Bool {
        segmentationStateLock.lock()
        defer { segmentationStateLock.unlock() }

        guard !segmentationInFlight else {
            return false
        }

        segmentationInFlight = true
        return true
    }

    private func finishSegmentation() {
        segmentationStateLock.lock()
        segmentationInFlight = false
        segmentationStateLock.unlock()
    }

    private func setStatus(_ status: String) {
        DispatchQueue.main.async {
            self.statusText = status
        }
    }

    private func updateMeasuredFPS() {
        renderedFrameCounter += 1
        let now = CACurrentMediaTime()
        guard now - lastFPSUpdate >= 1 else { return }

        let fps = Double(renderedFrameCounter) / (now - lastFPSUpdate)
        renderedFrameCounter = 0
        lastFPSUpdate = now

        DispatchQueue.main.async {
            self.measuredFramesPerSecond = fps
        }
    }
}

extension CameraPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        frameCounter += 1
        let settings = currentSettings()
        let shouldRefreshMask = currentMask() == nil
            || frameCounter.isMultiple(of: UInt64(max(1, settings.maskReuseFrameCount + 1)))

        if shouldRefreshMask {
            scheduleSegmentation(for: pixelBuffer)
        }

        scheduleRender(
            pixelBuffer: pixelBuffer,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }
}

extension CameraPipeline: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              Self.isCompleteOrIdleScreenCaptureFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        setLatestWindowBackgroundPixelBuffer(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        screenCaptureQueue.async {
            guard self.windowBackgroundStream === stream else { return }

            self.windowBackgroundStream = nil
            self.clearLatestWindowBackgroundPixelBuffer()
            DispatchQueue.main.async {
                self.selectedWindowBackgroundTitle = nil
                self.windowBackgroundStatusText = error.localizedDescription
            }
        }
    }

    private static func isCompleteOrIdleScreenCaptureFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }

        return status == .complete || status == .idle || status == .started
    }
}
