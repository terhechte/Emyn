import AppKit
import AVFoundation
import BackgroundRemovalKit
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import PlatformMacOSKit
import QuartzCore
import ScreenCaptureKit
import SharedFrameKit
import UniformTypeIdentifiers
import WindowCaptureKit

public struct CameraDeviceInfo: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let detail: String

    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

public enum CameraInputQuality: String, CaseIterable, Identifiable {
    case hd720
    case hd1080
    case uhd4K

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hd720:
            return "720p"
        case .hd1080:
            return "1080p"
        case .uhd4K:
            return "4K"
        }
    }

    public var dimensionsTitle: String {
        switch self {
        case .hd720:
            return "1280x720"
        case .hd1080:
            return "1920x1080"
        case .uhd4K:
            return "3840x2160"
        }
    }

    public var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720:
            return .hd1280x720
        case .hd1080:
            return .hd1920x1080
        case .uhd4K:
            return .hd4K3840x2160
        }
    }
}

public enum BackgroundMediaKind {
    case image
    case video

    public var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        }
    }
}

private enum BackgroundMediaError: LocalizedError {
    case unsupportedFileType
    case imageCouldNotBeLoaded
    case videoCouldNotBeLoaded

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Choose an image or video file."
        case .imageCouldNotBeLoaded:
            return "The selected image could not be loaded."
        case .videoCouldNotBeLoaded:
            return "The selected video could not be loaded."
        }
    }
}

public enum BackgroundPreset: String, CaseIterable, Identifiable {
    case black
    case white
    case green
    case blue
    case transparent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .green: return "Green"
        case .blue: return "Blue"
        case .transparent: return "Transparent"
        }
    }

    public var rgba: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
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

    public var nsColor: NSColor {
        let value = rgba
        return NSColor(
            calibratedRed: value.red,
            green: value.green,
            blue: value.blue,
            alpha: max(value.alpha, 0.18)
        )
    }
}

public enum NtscPreset: String, CaseIterable, Identifiable {
    case low
    case medium
    case hard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }

    public var platformPreset: PlatformMacOSKit.NtscEffectPreset {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .hard: return .hard
        }
    }
}

private struct ProcessingSettings {
    var backgroundRemovalEnabled = true
    var quality: SegmentationQuality = BackgroundRemovalDefaults.loadQuality()
    var analysisResolution: SegmentationAnalysisResolution = BackgroundRemovalDefaults.loadAnalysisResolution()
    var temporalSmoothing: Double = BackgroundRemovalDefaults.loadTemporalSmoothing()
    var maskBlurRadius: Double = BackgroundRemovalDefaults.loadMaskBlurRadius()
    var maskReuseFrameCount: Int = BackgroundRemovalDefaults.loadMaskReuseFrameCount()
    var backgroundColorEnabled = true
    var backgroundBlurEnabled = false
    var backgroundMediaEnabled = false
    var backgroundBlurRadius: Double = 18
    var background: BackgroundPreset = .black
    var backgroundMediaBlurRadius: Double = 0
    var backgroundMediaFit: BackgroundMediaFit = .fill
    var backgroundMediaAlignment: BackgroundContentAlignment = .middleCenter
    var windowBackgroundFit: BackgroundMediaFit = .fill
    var windowBackgroundAlignment: BackgroundContentAlignment = .middleCenter
    var outputFrameSize: OutputFrameSize = SharedFrameConfiguration.outputFrameSize
    var outputFlipHorizontal = false
    var outputFlipVertical = false
    var ntscEffectEnabled = false
    var ntscPreset: NtscPreset = .medium
    var presentationEffects = PresentationEffects()
    var speechCaptionText: String?
    var speechCaptionConfiguration = CaptionRenderConfiguration.defaultValue
}

private struct SpeechCaptionOverlayCacheKey: Equatable {
    var text: String
    var configuration: CaptionRenderConfiguration
    var size: CGSize
}

private struct AnimatedScalar {
    var startValue: Double
    var targetValue: Double
    var startTime: CFTimeInterval
    var duration: CFTimeInterval

    init(value: Double) {
        startValue = value
        targetValue = value
        startTime = CACurrentMediaTime()
        duration = 0
    }

    func value(at time: CFTimeInterval) -> Double {
        guard duration > 0 else { return targetValue }

        let progress = max(0, min(1, (time - startTime) / duration))
        let eased = progress * progress * (3 - 2 * progress)
        return startValue + (targetValue - startValue) * eased
    }

    mutating func animate(to value: Double, duration: CFTimeInterval, at time: CFTimeInterval) {
        startValue = self.value(at: time)
        targetValue = value
        startTime = time
        self.duration = duration
    }

    mutating func set(_ value: Double, at time: CFTimeInterval) {
        startValue = value
        targetValue = value
        startTime = time
        duration = 0
    }
}

private struct ConfettiBurst {
    static let duration: CFTimeInterval = 3.2

    let startTime: CFTimeInterval
    let seed: UInt64

    func isActive(at time: CFTimeInterval) -> Bool {
        time >= startTime && time - startTime <= Self.duration
    }

    func progress(at time: CFTimeInterval) -> CGFloat? {
        let elapsed = time - startTime
        guard elapsed <= Self.duration else {
            return nil
        }

        return CGFloat(max(0, elapsed) / Self.duration)
    }
}

private struct PresentationEffects {
    var windowBackgroundOpacity = AnimatedScalar(value: 1)
    var personScale = AnimatedScalar(value: 1)
    var windowZoom = AnimatedScalar(value: 1)
    var windowZoomCenter = CGPoint(x: 0.5, y: 0.5)
    var activeImageOverlayPathsByID: [String: String] = [:]
    var confettiBursts: [ConfettiBurst] = []

    private var nextConfettiBurstID = 0

    mutating func setWindowBackgroundVisible(_ isVisible: Bool, animated: Bool, at time: CFTimeInterval) {
        let opacity = isVisible ? 1.0 : 0.0
        if animated {
            windowBackgroundOpacity.animate(to: opacity, duration: 1, at: time)
        } else {
            windowBackgroundOpacity.set(opacity, at: time)
        }
    }

    mutating func toggleWindowBackgroundVisibility(at time: CFTimeInterval) {
        windowBackgroundOpacity.animate(
            to: windowBackgroundOpacity.targetValue > 0.5 ? 0 : 1,
            duration: 1,
            at: time
        )
    }

    mutating func togglePersonPosition(at time: CFTimeInterval) {
        personScale.animate(
            to: personScale.targetValue > 0.75 ? 0.5 : 1,
            duration: 0.35,
            at: time
        )
    }

    mutating func toggleWindowAndPersonPresentation(at time: CFTimeInterval) {
        let isPresentingWindowWithCompactPerson = windowBackgroundOpacity.targetValue > 0.5
            && personScale.targetValue < 0.75

        windowBackgroundOpacity.animate(
            to: isPresentingWindowWithCompactPerson ? 0 : 1,
            duration: 1,
            at: time
        )
        personScale.animate(
            to: isPresentingWindowWithCompactPerson ? 1 : 0.5,
            duration: 1,
            at: time
        )
    }

    mutating func toggleWindowZoom(at time: CFTimeInterval) {
        windowZoom.animate(
            to: windowZoom.targetValue > 1.5 ? 1 : 2,
            duration: 1,
            at: time
        )
    }

    mutating func triggerConfetti(at time: CFTimeInterval) {
        confettiBursts.removeAll { !$0.isActive(at: time) }
        nextConfettiBurstID += 1

        let timeSeed = UInt64(max(0, time * 1_000))
        let seed = (UInt64(nextConfettiBurstID) &* 0x9E37_79B9_7F4A_7C15) ^ timeSeed
        confettiBursts.append(ConfettiBurst(
            startTime: time,
            seed: seed
        ))

        if confettiBursts.count > 4 {
            confettiBursts.removeFirst(confettiBursts.count - 4)
        }
    }

    func resolved(at time: CFTimeInterval) -> ResolvedPresentationEffects {
        ResolvedPresentationEffects(
            windowBackgroundOpacity: windowBackgroundOpacity.value(at: time),
            personScale: personScale.value(at: time),
            windowZoom: windowZoom.value(at: time),
            windowZoomCenter: windowZoomCenter,
            activeImageOverlayPaths: activeImageOverlayPathsByID
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map(\.value),
            confettiBursts: confettiBursts.filter { $0.isActive(at: time) }
        )
    }
}

private struct ResolvedPresentationEffects {
    var windowBackgroundOpacity: Double
    var personScale: Double
    var windowZoom: Double
    var windowZoomCenter: CGPoint
    var activeImageOverlayPaths: [String]
    var confettiBursts: [ConfettiBurst]
}

private struct RenderFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
}

private struct WindowBackgroundFrameSnapshot {
    let pixelBuffer: CVPixelBuffer
    let fadeSourcePixelBuffer: CVPixelBuffer?
    let fadeProgress: Double
}

public final class CameraPipeline: NSObject, ObservableObject {
    @Published public private(set) var cameras: [CameraDeviceInfo] = []
    @Published public var selectedCameraID: String = "" {
        didSet {
            guard oldValue != selectedCameraID, isRunning else { return }
            restart()
        }
    }

    @Published public var cameraInputQuality: CameraInputQuality = .hd720 {
        didSet {
            guard oldValue != cameraInputQuality, isRunning else { return }
            restart()
        }
    }

    @Published public var backgroundRemovalEnabled = true {
        didSet {
            updateSettings { $0.backgroundRemovalEnabled = self.backgroundRemovalEnabled }
            updateBackgroundMediaPlaybackState()
            if !backgroundRemovalEnabled {
                clearMask()
            }
        }
    }

    @Published public var quality: SegmentationQuality = BackgroundRemovalDefaults.loadQuality() {
        didSet {
            BackgroundRemovalDefaults.saveQuality(quality)
            updateSettings { $0.quality = self.quality }
        }
    }

    @Published public var analysisResolution: SegmentationAnalysisResolution = BackgroundRemovalDefaults.loadAnalysisResolution() {
        didSet {
            BackgroundRemovalDefaults.saveAnalysisResolution(analysisResolution)
            updateSettings { $0.analysisResolution = self.analysisResolution }
            clearMask()
        }
    }

    @Published public var temporalSmoothing: Double = BackgroundRemovalDefaults.loadTemporalSmoothing() {
        didSet {
            BackgroundRemovalDefaults.saveTemporalSmoothing(temporalSmoothing)
            updateSettings { $0.temporalSmoothing = self.temporalSmoothing }
        }
    }

    @Published public var maskBlurRadius: Double = BackgroundRemovalDefaults.loadMaskBlurRadius() {
        didSet {
            BackgroundRemovalDefaults.saveMaskBlurRadius(maskBlurRadius)
            updateSettings { $0.maskBlurRadius = self.maskBlurRadius }
            refreshCurrentRenderMask(blurRadius: maskBlurRadius, outputFrameSize: outputFrameSize)
        }
    }

    @Published public var maskReuseFrameCount: Int = BackgroundRemovalDefaults.loadMaskReuseFrameCount() {
        didSet {
            BackgroundRemovalDefaults.saveMaskReuseFrameCount(maskReuseFrameCount)
            updateSettings { $0.maskReuseFrameCount = self.maskReuseFrameCount }
        }
    }

    @Published public var backgroundColorEnabled = true {
        didSet { updateSettings { $0.backgroundColorEnabled = self.backgroundColorEnabled } }
    }

    @Published public var backgroundBlurEnabled = false {
        didSet { updateSettings { $0.backgroundBlurEnabled = self.backgroundBlurEnabled } }
    }

    @Published public var backgroundMediaEnabled = false {
        didSet {
            updateSettings { $0.backgroundMediaEnabled = self.backgroundMediaEnabled }
            updateBackgroundMediaPlaybackState()
        }
    }

    @Published public var backgroundBlurRadius: Double = 18 {
        didSet { updateSettings { $0.backgroundBlurRadius = self.backgroundBlurRadius } }
    }

    @Published public var backgroundPreset: BackgroundPreset = .black {
        didSet { updateSettings { $0.background = self.backgroundPreset } }
    }

    @Published public var backgroundMediaBlurRadius: Double = 0 {
        didSet { updateSettings { $0.backgroundMediaBlurRadius = self.backgroundMediaBlurRadius } }
    }

    @Published public var backgroundMediaFit: BackgroundMediaFit = .fill {
        didSet { updateSettings { $0.backgroundMediaFit = self.backgroundMediaFit } }
    }

    @Published public var backgroundMediaAlignment: BackgroundContentAlignment = .middleCenter {
        didSet { updateSettings { $0.backgroundMediaAlignment = self.backgroundMediaAlignment } }
    }

    @Published public var windowBackgroundFit: BackgroundMediaFit = .fill {
        didSet { updateSettings { $0.windowBackgroundFit = self.windowBackgroundFit } }
    }

    @Published public var windowBackgroundAlignment: BackgroundContentAlignment = .middleCenter {
        didSet { updateSettings { $0.windowBackgroundAlignment = self.windowBackgroundAlignment } }
    }

    @Published public var outputFrameSize: OutputFrameSize = SharedFrameConfiguration.outputFrameSize {
        didSet {
            guard oldValue != outputFrameSize else { return }

            let newValue = outputFrameSize
            SharedFrameConfiguration.outputFrameSize = newValue
            updateSettings { $0.outputFrameSize = newValue }
            clearMask()

            renderQueue.async {
                self.resetOutputResources(for: newValue)
            }

            if hasWindowBackgroundSelection {
                startActiveWindowBackgroundCapture(statusPrefix: "Resizing")
            }
        }
    }

    @Published public var outputFlipHorizontal = false {
        didSet { updateSettings { $0.outputFlipHorizontal = self.outputFlipHorizontal } }
    }

    @Published public var outputFlipVertical = false {
        didSet { updateSettings { $0.outputFlipVertical = self.outputFlipVertical } }
    }

    @Published public var ntscEffectEnabled = false {
        didSet { updateSettings { $0.ntscEffectEnabled = self.ntscEffectEnabled } }
    }

    @Published public var ntscPreset: NtscPreset = .medium {
        didSet { updateSettings { $0.ntscPreset = self.ntscPreset } }
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var statusText = "Idle"
    @Published public private(set) var measuredFramesPerSecond: Double = 0
    @Published public private(set) var selectedWindowBackgroundTitle: String?
    @Published public private(set) var selectedWindowBackgroundOptions: [WindowBackgroundOption] = []
    @Published public private(set) var activeWindowBackgroundIndex: Int?
    @Published public private(set) var windowBackgroundStatusText = "Color background"
    @Published public private(set) var selectedBackgroundMediaTitle: String?
    @Published public private(set) var selectedBackgroundMediaKind: BackgroundMediaKind?
    @Published public private(set) var backgroundMediaStatusText = "No media selected"

    public var previewHandler: ((CMSampleBuffer) -> Void)?

    public var hasWindowBackgroundSelection: Bool {
        !selectedWindowBackgroundOptions.isEmpty
    }

    public var hasBackgroundMediaSelection: Bool {
        selectedBackgroundMediaKind != nil
    }

    public func setSpeechCaptionOverlay(text: String?, configuration: CaptionRenderConfiguration) {
        updateSettings { settings in
            settings.speechCaptionText = text
            settings.speechCaptionConfiguration = configuration
        }
    }

    public var activeWindowBackgroundOption: WindowBackgroundOption? {
        guard let activeWindowBackgroundIndex,
              selectedWindowBackgroundOptions.indices.contains(activeWindowBackgroundIndex) else {
            return nil
        }

        return selectedWindowBackgroundOptions[activeWindowBackgroundIndex]
    }

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.stylemac.Emyn.capture", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "com.stylemac.Emyn.render", qos: .userInteractive)
    private let settingsQueue = DispatchQueue(label: "com.stylemac.Emyn.settings")
    private let backgroundLock = NSLock()
    private let backgroundMediaLock = NSLock()
    private let imageOverlayLock = NSLock()
    private let speechCaptionOverlayLock = NSLock()
    private let renderGate = LatestFrameRenderGate<RenderFrame>()

    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let backgroundRemover = PersonBackgroundRemover()
    private let frameWriter: SharedFrameWriter?
    private static let windowBackgroundCycleFadeDuration: CFTimeInterval = 0.5
    private static let confettiParticleCount = 144
    private static let confettiReferenceOutputSize = CGSize(width: 1280, height: 720)
    private static let confettiParticleScale: CGFloat = 1.3
    private static let confettiPalette: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [
        (0.98, 0.20, 0.30),
        (1.00, 0.70, 0.12),
        (0.13, 0.75, 0.38),
        (0.10, 0.48, 0.95),
        (0.70, 0.25, 0.95),
        (0.08, 0.78, 0.82)
    ]

    private var settings = ProcessingSettings()
    private var outputPixelBufferPool: CVPixelBufferPool?
    private var outputPixelBufferPoolSize = CGSize(width: 0, height: 0)
    private var ntscPixelBufferPool: CVPixelBufferPool?
    private var ntscPixelBufferPoolSize = CGSize(width: 0, height: 0)
    private var confettiOverlayPixelBufferPool: CVPixelBufferPool?
    private var confettiOverlayPixelBufferPoolSize = CGSize(width: 0, height: 0)
    private var speechCaptionOverlayPixelBufferPool: CVPixelBufferPool?
    private var speechCaptionOverlayPixelBufferPoolSize = CGSize(width: 0, height: 0)
    private var speechCaptionOverlayCache: CGImage?
    private var speechCaptionOverlayCacheKey: SpeechCaptionOverlayCacheKey?
    private var outputFormatDescription: CMFormatDescription?
    private var outputFormatDescriptionSize = CGSize(width: 0, height: 0)
    private var frameCounter: UInt64 = 0
    private var renderedFrameCounter = 0
    private var ntscEffectFrameCounter: UInt64 = 0
    private var didReportNtscEffectError = false
    private var lastFPSUpdate = CACurrentMediaTime()
    private let windowBackgroundStream = WindowCaptureStream()
    private var latestWindowBackgroundPixelBuffer: CVPixelBuffer?
    private var windowBackgroundFadeSourcePixelBuffer: CVPixelBuffer?
    private var windowBackgroundFadeStartTime: CFTimeInterval?
    private var windowBackgroundFadeDuration: CFTimeInterval = 0
    private var shouldFadeNextWindowBackgroundFrame = false
    private var backgroundMediaImage: CIImage?
    private var backgroundMediaPlayer: AVPlayer?
    private var backgroundMediaVideoOutput: AVPlayerItemVideoOutput?
    private var backgroundMediaVideoTransform: CGAffineTransform = .identity
    private var latestBackgroundMediaVideoImage: CIImage?
    private var backgroundMediaLoopObserver: NSObjectProtocol?
    private var imageOverlayCache: [String: CIImage] = [:]
    private var outputFrameSizeObserverTimer: DispatchSourceTimer?

    public override init() {
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

        settings.outputFrameSize = outputFrameSize
        backgroundRemover.onError = { [weak self] error in
            self?.setStatus(error.localizedDescription)
        }
        let outputSize = CGSize(width: outputFrameSize.width, height: outputFrameSize.height)
        outputPixelBufferPool = Self.makePixelBufferPool(
            width: outputFrameSize.width,
            height: outputFrameSize.height,
            pixelFormat: SharedFrameConfiguration.pixelFormat
        )
        outputPixelBufferPoolSize = outputSize
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: SharedFrameConfiguration.pixelFormat,
            width: Int32(outputFrameSize.width),
            height: Int32(outputFrameSize.height),
            extensions: nil,
            formatDescriptionOut: &outputFormatDescription
        )
        outputFormatDescriptionSize = outputSize

        refreshCameras()
        startOutputFrameSizeObserver()
        if frameWriter == nil {
            statusText = "Shared frame output unavailable"
        }
    }

    deinit {
        outputFrameSizeObserverTimer?.cancel()
        clearBackgroundMediaResources()
    }

    public func refreshCameras() {
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

    private func startOutputFrameSizeObserver() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.syncOutputFrameSizeFromSharedDefaults()
        }
        timer.resume()
        outputFrameSizeObserverTimer = timer
    }

    private func syncOutputFrameSizeFromSharedDefaults() {
        let sharedOutputFrameSize = SharedFrameConfiguration.synchronizedOutputFrameSize()
        guard outputFrameSize != sharedOutputFrameSize else { return }
        outputFrameSize = sharedOutputFrameSize
    }

    public func start() {
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

    public func stop() {
        setBackgroundMediaPlayback(shouldPlay: false)

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

    public func selectBackgroundMedia(url: URL) {
        do {
            let kind = try Self.mediaKind(for: url)
            switch kind {
            case .image:
                try selectBackgroundImage(url: url)
            case .video:
                try selectBackgroundVideo(url: url)
            }

            selectedBackgroundMediaTitle = url.deletingPathExtension().lastPathComponent
            selectedBackgroundMediaKind = kind
            backgroundMediaStatusText = "Using \(kind.title.lowercased()) background"
            backgroundMediaEnabled = true
        } catch {
            backgroundMediaStatusText = error.localizedDescription
            setStatus("Background media failed: \(error.localizedDescription)")
        }
    }

    public func clearBackgroundMedia() {
        clearBackgroundMediaResources()
        selectedBackgroundMediaTitle = nil
        selectedBackgroundMediaKind = nil
        backgroundMediaStatusText = "No media selected"
        backgroundMediaEnabled = false
    }

    public func selectWindowBackground(_ option: WindowBackgroundOption) {
        selectWindowBackgrounds([option])
    }

    public func selectWindowBackgrounds(_ options: [WindowBackgroundOption]) {
        let uniqueOptions = Self.deduplicatedWindowOptions(options)
        guard !uniqueOptions.isEmpty else {
            clearWindowBackground()
            return
        }

        setWindowBackgroundVisible(true, animated: false)
        selectedWindowBackgroundOptions = uniqueOptions
        activeWindowBackgroundIndex = 0
        startActiveWindowBackgroundCapture(statusPrefix: "Starting")
    }

    public func removeWindowBackground(id: CGWindowID) {
        guard let removedIndex = selectedWindowBackgroundOptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedActiveWindow = activeWindowBackgroundIndex == removedIndex
        selectedWindowBackgroundOptions.remove(at: removedIndex)

        guard !selectedWindowBackgroundOptions.isEmpty else {
            clearWindowBackground()
            return
        }

        if removedActiveWindow {
            activeWindowBackgroundIndex = min(removedIndex, selectedWindowBackgroundOptions.count - 1)
            startActiveWindowBackgroundCapture(statusPrefix: "Switching to")
        } else if let activeWindowBackgroundIndex, removedIndex < activeWindowBackgroundIndex {
            self.activeWindowBackgroundIndex = activeWindowBackgroundIndex - 1
        }
    }

    public func moveWindowBackgrounds(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }

        let activeID = activeWindowBackgroundOption?.id
        let movingIndexes = source.sorted()
        let movingOptions = movingIndexes.map { selectedWindowBackgroundOptions[$0] }
        for index in movingIndexes.reversed() {
            selectedWindowBackgroundOptions.remove(at: index)
        }

        let adjustedDestination = destination - movingIndexes.filter { $0 < destination }.count
        let insertionIndex = max(0, min(adjustedDestination, selectedWindowBackgroundOptions.count))
        selectedWindowBackgroundOptions.insert(contentsOf: movingOptions, at: insertionIndex)

        if let activeID,
           let newIndex = selectedWindowBackgroundOptions.firstIndex(where: { $0.id == activeID }) {
            activeWindowBackgroundIndex = newIndex
            let title = windowBackgroundTitle(
                for: selectedWindowBackgroundOptions[newIndex],
                index: newIndex,
                total: selectedWindowBackgroundOptions.count
            )
            selectedWindowBackgroundTitle = title
            windowBackgroundStatusText = "Using \(title)"
        }
    }

    public func clearWindowBackground() {
        selectedWindowBackgroundTitle = nil
        selectedWindowBackgroundOptions = []
        activeWindowBackgroundIndex = nil
        windowBackgroundStatusText = "Color background"
        clearLatestWindowBackgroundPixelBuffer()

        stopWindowBackgroundStream()
    }

    @discardableResult
    public func cycleWindowBackground() -> WindowBackgroundOption? {
        guard selectedWindowBackgroundOptions.count > 1 else {
            return activeWindowBackgroundOption
        }

        let currentIndex = activeWindowBackgroundIndex ?? 0
        activeWindowBackgroundIndex = selectedWindowBackgroundOptions.index(after: currentIndex)
        if activeWindowBackgroundIndex == selectedWindowBackgroundOptions.endIndex {
            activeWindowBackgroundIndex = selectedWindowBackgroundOptions.startIndex
        }

        startActiveWindowBackgroundCapture(statusPrefix: "Switching to", animated: true)
        return activeWindowBackgroundOption
    }

    public func setWindowBackgroundVisible(_ isVisible: Bool, animated: Bool) {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.setWindowBackgroundVisible(isVisible, animated: animated, at: now)
        }
    }

    public func toggleWindowBackgroundVisibility() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.toggleWindowBackgroundVisibility(at: now)
        }
    }

    public func togglePersonCompactPosition() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.togglePersonPosition(at: now)
        }
    }

    public func toggleWindowAndCompactPerson() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.toggleWindowAndPersonPresentation(at: now)
        }
    }

    public func toggleWindowZoom() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.toggleWindowZoom(at: now)
        }
    }

    public func setWindowZoomCenter(_ center: CGPoint?) {
        let clampedCenter = CGPoint(
            x: max(0, min(1, center?.x ?? 0.5)),
            y: max(0, min(1, center?.y ?? 0.5))
        )
        updateSettings { settings in
            settings.presentationEffects.windowZoomCenter = clampedCenter
        }
    }

    public func toggleImageOverlay(identifier: String, imagePath: String) {
        updateSettings { settings in
            if settings.presentationEffects.activeImageOverlayPathsByID[identifier] == nil {
                settings.presentationEffects.activeImageOverlayPathsByID[identifier] = imagePath
            } else {
                settings.presentationEffects.activeImageOverlayPathsByID.removeValue(forKey: identifier)
            }
        }
    }

    public func triggerConfetti() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.triggerConfetti(at: now)
        }
    }

    public func toggleNtscEffect() {
        ntscEffectEnabled.toggle()
    }

    public func restart() {
        stop()
        captureQueue.asyncAfter(deadline: .now() + 0.25) {
            self.configureAndStartCapture()
        }
    }

    private func configureAndStartCapture() {
        let cameraID = selectedCameraID
        let requestedInputQuality = cameraInputQuality
        captureQueue.async {
            guard let device = Self.discoverCameraDevices().first(where: { $0.uniqueID == cameraID })
                    ?? Self.discoverCameraDevices().first else {
                self.setStatus("No camera found")
                return
            }

            do {
                self.captureSession.beginConfiguration()
                self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
                self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }

                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else {
                    self.captureSession.commitConfiguration()
                    self.setStatus("Camera input unavailable")
                    return
                }

                self.captureSession.addInput(input)
                let appliedInputQuality = Self.applyCameraInputQuality(
                    requestedInputQuality,
                    to: self.captureSession
                )
                self.pinCameraFrameRate(30, on: device)
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
                    if appliedInputQuality == requestedInputQuality {
                        self.statusText = "Running"
                    } else if let appliedInputQuality {
                        self.statusText = "Running at \(appliedInputQuality.title) input"
                    } else {
                        self.statusText = "Running with camera default input"
                    }
                    self.updateBackgroundMediaPlaybackState()
                }
            } catch {
                self.captureSession.commitConfiguration()
                self.setStatus(error.localizedDescription)
            }
        }
    }

    private func pinCameraFrameRate(_ frameRate: Int32, on device: AVCaptureDevice) {
        let frameDuration = CMTime(value: 1, timescale: frameRate)
        let supportsFrameRate = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
            CMTimeCompare(range.minFrameDuration, frameDuration) <= 0
                && CMTimeCompare(frameDuration, range.maxFrameDuration) >= 0
        }
        guard supportsFrameRate else { return }

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            setStatus("Camera frame rate configuration failed: \(error.localizedDescription)")
        }
    }

    private static func applyCameraInputQuality(
        _ requestedInputQuality: CameraInputQuality,
        to captureSession: AVCaptureSession
    ) -> CameraInputQuality? {
        if captureSession.canSetSessionPreset(requestedInputQuality.sessionPreset) {
            captureSession.sessionPreset = requestedInputQuality.sessionPreset
            return requestedInputQuality
        }

        let qualities = CameraInputQuality.allCases
        guard let requestedIndex = qualities.firstIndex(of: requestedInputQuality) else {
            return nil
        }

        for quality in qualities[...requestedIndex].reversed() where captureSession.canSetSessionPreset(quality.sessionPreset) {
            captureSession.sessionPreset = quality.sessionPreset
            return quality
        }

        if requestedIndex + 1 < qualities.endIndex {
            for quality in qualities[(requestedIndex + 1)...] where captureSession.canSetSessionPreset(quality.sessionPreset) {
                captureSession.sessionPreset = quality.sessionPreset
                return quality
            }
        }

        return nil
    }

    private static func discoverCameraDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices.filter { $0.localizedName != SharedFrameConfiguration.virtualCameraName }
    }

    private func selectBackgroundImage(url: URL) throws {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw BackgroundMediaError.imageCouldNotBeLoaded
        }

        clearBackgroundMediaResources()
        backgroundMediaLock.lock()
        backgroundMediaImage = normalizeExtent(image)
        backgroundMediaLock.unlock()
    }

    private func selectBackgroundVideo(url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw BackgroundMediaError.videoCouldNotBeLoaded
        }

        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none

        clearBackgroundMediaResources()
        backgroundMediaLock.lock()
        backgroundMediaPlayer = player
        backgroundMediaVideoOutput = output
        backgroundMediaVideoTransform = videoTrack.preferredTransform
        latestBackgroundMediaVideoImage = nil
        backgroundMediaLock.unlock()

        backgroundMediaLoopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self, let player, self.isCurrentBackgroundMediaPlayer(player) else { return }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async {
                    guard self.isCurrentBackgroundMediaPlayer(player) else { return }
                    self.updateBackgroundMediaPlaybackState()
                }
            }
        }

        updateBackgroundMediaPlaybackState()
    }

    private static func mediaKind(for url: URL) throws -> BackgroundMediaKind {
        let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let filenameType = UTType(filenameExtension: url.pathExtension)
        let contentType = resourceType ?? filenameType

        guard let contentType else {
            throw BackgroundMediaError.unsupportedFileType
        }

        if contentType.conforms(to: .image) {
            return .image
        }

        if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
            return .video
        }

        throw BackgroundMediaError.unsupportedFileType
    }

    private func clearBackgroundMediaResources() {
        if let backgroundMediaLoopObserver {
            NotificationCenter.default.removeObserver(backgroundMediaLoopObserver)
            self.backgroundMediaLoopObserver = nil
        }

        backgroundMediaLock.lock()
        let player = backgroundMediaPlayer
        backgroundMediaImage = nil
        backgroundMediaPlayer = nil
        backgroundMediaVideoOutput = nil
        backgroundMediaVideoTransform = .identity
        latestBackgroundMediaVideoImage = nil
        backgroundMediaLock.unlock()

        player?.pause()
    }

    private func updateBackgroundMediaPlaybackState() {
        setBackgroundMediaPlayback(shouldPlay: isRunning && backgroundRemovalEnabled && backgroundMediaEnabled)
    }

    private func setBackgroundMediaPlayback(shouldPlay: Bool) {
        backgroundMediaLock.lock()
        let player = backgroundMediaPlayer
        backgroundMediaLock.unlock()

        if shouldPlay {
            player?.play()
        } else {
            player?.pause()
        }
    }

    private func isCurrentBackgroundMediaPlayer(_ player: AVPlayer) -> Bool {
        backgroundMediaLock.lock()
        defer { backgroundMediaLock.unlock() }
        return backgroundMediaPlayer === player
    }

    private func scheduleSegmentation(for pixelBuffer: CVPixelBuffer) {
        let settings = currentSettings()
        let outputSize = CGSize(
            width: settings.outputFrameSize.width,
            height: settings.outputFrameSize.height
        )
        backgroundRemover.process(
            pixelBuffer: pixelBuffer,
            configuration: PersonSegmentationConfiguration(
                quality: settings.quality,
                analysisResolution: settings.analysisResolution,
                temporalSmoothing: settings.temporalSmoothing,
                maskBlurRadius: settings.maskBlurRadius,
                outputSize: outputSize
            )
        )
    }

    private func scheduleRender(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let frame = RenderFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        guard let acceptedFrame = renderGate.begin(with: frame) else {
            return
        }

        enqueueRender(acceptedFrame)
    }

    private func enqueueRender(_ frame: RenderFrame) {
        renderQueue.async {
            autoreleasepool {
                self.render(pixelBuffer: frame.pixelBuffer, timestamp: frame.timestamp)
            }
            self.finishRender()
        }
    }

    private func finishRender() {
        if let pendingFrame = renderGate.finish() {
            enqueueRender(pendingFrame)
        }
    }

    private func render(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let settings = currentSettings()
        let outputSize = CGSize(width: settings.outputFrameSize.width, height: settings.outputFrameSize.height)
        guard let outputPixelBuffer = makeOutputPixelBuffer(size: outputSize) else {
            return
        }

        let outputExtent = CGRect(origin: .zero, size: outputSize)
        let foreground = aspectFillImage(from: pixelBuffer, targetSize: outputSize)
        let renderTime = CACurrentMediaTime()
        let effects = settings.presentationEffects.resolved(at: renderTime)

        var renderedImage: CIImage
        if settings.backgroundRemovalEnabled, let mask = currentRenderMask() {
            let background = backgroundImage(
                settings: settings,
                effects: effects,
                foreground: foreground,
                outputExtent: outputExtent,
                at: renderTime
            )

            renderedImage = composePerson(
                foreground: foreground,
                mask: mask,
                background: background,
                outputExtent: outputExtent,
                scale: effects.personScale
            )
        } else {
            renderedImage = foreground.cropped(to: outputExtent)
        }

        renderedImage = applyImageOverlays(
            effects.activeImageOverlayPaths,
            over: renderedImage,
            outputExtent: outputExtent
        )
        renderedImage = applyConfetti(
            effects.confettiBursts,
            over: renderedImage,
            outputExtent: outputExtent,
            at: renderTime
        )
        let hasSpeechCaption = hasSpeechCaption(settings)
        if hasSpeechCaption, settings.speechCaptionConfiguration.isAffectedByNTSC {
            renderedImage = applySpeechCaptionOverlay(
                over: renderedImage,
                outputExtent: outputExtent,
                settings: settings
            )
        }
        renderedImage = applyOutputFlips(
            to: renderedImage,
            outputExtent: outputExtent,
            horizontal: settings.outputFlipHorizontal,
            vertical: settings.outputFlipVertical
        )

        ciContext.render(
            renderedImage,
            to: outputPixelBuffer,
            bounds: outputExtent,
            colorSpace: colorSpace
        )

        if settings.ntscEffectEnabled {
            applyNtscEffect(to: outputPixelBuffer, preset: settings.ntscPreset)
        }

        if hasSpeechCaption, !settings.speechCaptionConfiguration.isAffectedByNTSC {
            drawSpeechCaption(to: outputPixelBuffer, outputExtent: outputExtent, settings: settings)
        }

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

    private func backgroundImage(
        settings: ProcessingSettings,
        effects: ResolvedPresentationEffects,
        foreground: CIImage,
        outputExtent: CGRect,
        at time: CFTimeInterval
    ) -> CIImage {
        let baseBackground = baseBackgroundImage(
            settings: settings,
            foreground: foreground,
            outputExtent: outputExtent
        )

        guard let frameSnapshot = currentWindowBackgroundFrame(at: time) else {
            return baseBackground
        }

        let opacity = max(0, min(1, effects.windowBackgroundOpacity))
        guard opacity > 0.001 else {
            return baseBackground
        }

        var windowBackground = preparedWindowBackgroundImage(
            from: frameSnapshot.pixelBuffer,
            settings: settings,
            effects: effects,
            outputExtent: outputExtent,
            backing: baseBackground
        )

        if let fadeSourcePixelBuffer = frameSnapshot.fadeSourcePixelBuffer,
           frameSnapshot.fadeProgress < 0.999 {
            let fadeSourceBackground = preparedWindowBackgroundImage(
                from: fadeSourcePixelBuffer,
                settings: settings,
                effects: effects,
                outputExtent: outputExtent,
                backing: baseBackground
            )
            windowBackground = windowBackground
                .applyingFilter("CIMix", parameters: [
                    kCIInputBackgroundImageKey: fadeSourceBackground,
                    kCIInputAmountKey: max(0, min(1, frameSnapshot.fadeProgress))
                ])
                .cropped(to: outputExtent)
        }

        guard opacity < 0.999 else {
            return windowBackground
        }

        return windowBackground
            .applyingFilter("CIMix", parameters: [
                kCIInputBackgroundImageKey: baseBackground,
                kCIInputAmountKey: opacity
            ])
            .cropped(to: outputExtent)
    }

    private func preparedWindowBackgroundImage(
        from pixelBuffer: CVPixelBuffer,
        settings: ProcessingSettings,
        effects: ResolvedPresentationEffects,
        outputExtent: CGRect,
        backing baseBackground: CIImage
    ) -> CIImage {
        var windowBackground = fittedMediaBackgroundImage(
            CIImage(cvPixelBuffer: pixelBuffer),
            fit: settings.windowBackgroundFit,
            alignment: settings.windowBackgroundAlignment,
            outputExtent: outputExtent,
            backing: baseBackground
        )

        if effects.windowZoom > 1.001 {
            windowBackground = zoomedWindowBackground(
                windowBackground,
                zoom: effects.windowZoom,
                center: effects.windowZoomCenter,
                outputExtent: outputExtent
            )
        }

        return windowBackground
    }

    private func baseBackgroundImage(
        settings: ProcessingSettings,
        foreground: CIImage,
        outputExtent: CGRect
    ) -> CIImage {
        var background = settings.backgroundColorEnabled
            ? solidBackgroundImage(settings: settings, outputExtent: outputExtent)
            : CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: outputExtent)

        if settings.backgroundBlurEnabled {
            let radius = max(0, settings.backgroundBlurRadius)
            background = downsampledBlurredImage(
                foreground,
                radius: radius,
                outputExtent: outputExtent
            )
        }

        if settings.backgroundMediaEnabled,
           var mediaImage = currentBackgroundMediaImage() {
            let radius = max(0, settings.backgroundMediaBlurRadius)
            if radius > 0 {
                mediaImage = downsampledBlurredImage(
                    mediaImage,
                    radius: radius,
                    outputExtent: mediaImage.extent
                )
            }

            background = fittedMediaBackgroundImage(
                mediaImage,
                fit: settings.backgroundMediaFit,
                alignment: settings.backgroundMediaAlignment,
                outputExtent: outputExtent,
                backing: background
            )
        }

        return background
    }

    private func solidBackgroundImage(
        settings: ProcessingSettings,
        outputExtent: CGRect
    ) -> CIImage {
        let color = settings.background.rgba
        return CIImage(color: CIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        ))
        .cropped(to: outputExtent)
    }

    private func downsampledBlurredImage(
        _ image: CIImage,
        radius: Double,
        outputExtent: CGRect
    ) -> CIImage {
        guard radius > 0 else {
            return image.cropped(to: outputExtent)
        }

        let downsampleScale: CGFloat = radius >= 8 ? 0.25 : 0.5
        let downsampled = image
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
        let blurred = downsampled
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * downsampleScale])

        return blurred
            .transformed(by: CGAffineTransform(scaleX: 1 / downsampleScale, y: 1 / downsampleScale))
            .cropped(to: outputExtent)
    }

    private func fittedMediaBackgroundImage(
        _ image: CIImage,
        fit: BackgroundMediaFit,
        alignment: BackgroundContentAlignment,
        outputExtent: CGRect,
        backing: CIImage
    ) -> CIImage {
        let normalizedImage = normalizeExtent(image)
        guard normalizedImage.extent.width > 0, normalizedImage.extent.height > 0 else {
            return backing
        }

        let fittedImage: CIImage
        switch fit {
        case .fill:
            fittedImage = transformedMediaImage(
                normalizedImage,
                scaleX: max(outputExtent.width / normalizedImage.extent.width, outputExtent.height / normalizedImage.extent.height),
                scaleY: max(outputExtent.width / normalizedImage.extent.width, outputExtent.height / normalizedImage.extent.height),
                alignment: alignment,
                outputExtent: outputExtent
            )
        case .contain:
            fittedImage = transformedMediaImage(
                normalizedImage,
                scaleX: min(outputExtent.width / normalizedImage.extent.width, outputExtent.height / normalizedImage.extent.height),
                scaleY: min(outputExtent.width / normalizedImage.extent.width, outputExtent.height / normalizedImage.extent.height),
                alignment: alignment,
                outputExtent: outputExtent
            )
        case .scale:
            fittedImage = transformedMediaImage(
                normalizedImage,
                scaleX: outputExtent.width / normalizedImage.extent.width,
                scaleY: outputExtent.height / normalizedImage.extent.height,
                alignment: alignment,
                outputExtent: outputExtent
            )
        }

        return fittedImage
            .cropped(to: outputExtent)
            .composited(over: backing)
            .cropped(to: outputExtent)
    }

    private func transformedMediaImage(
        _ image: CIImage,
        scaleX: CGFloat,
        scaleY: CGFloat,
        alignment: BackgroundContentAlignment,
        outputExtent: CGRect
    ) -> CIImage {
        let scaledSize = CGSize(
            width: image.extent.width * scaleX,
            height: image.extent.height * scaleY
        )
        let origin = alignment.origin(for: scaledSize, in: outputExtent)

        return image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: origin.x,
                y: origin.y
            ))
    }

    private func composePerson(
        foreground: CIImage,
        mask: CIImage,
        background: CIImage,
        outputExtent: CGRect,
        scale: Double
    ) -> CIImage {
        let clampedScale = max(0.1, min(1, scale))

        if clampedScale >= 0.999 {
            return foreground.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask
            ])
            .cropped(to: outputExtent)
        }

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: outputExtent)
        let maskedForeground = foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask
        ])
        .cropped(to: outputExtent)

        return maskedForeground
            .transformed(by: CGAffineTransform(scaleX: clampedScale, y: clampedScale))
            .transformed(by: CGAffineTransform(
                translationX: outputExtent.width * (1 - clampedScale),
                y: 0
            ))
            .composited(over: background)
            .cropped(to: outputExtent)
    }

    private func zoomedWindowBackground(
        _ image: CIImage,
        zoom: Double,
        center: CGPoint,
        outputExtent: CGRect
    ) -> CIImage {
        let clampedZoom = max(1, min(4, zoom))
        let cropSize = CGSize(
            width: outputExtent.width / clampedZoom,
            height: outputExtent.height / clampedZoom
        )
        let anchorX = outputExtent.minX + outputExtent.width * max(0, min(1, center.x))
        let anchorY = outputExtent.minY + outputExtent.height * (1 - max(0, min(1, center.y)))
        let origin = CGPoint(
            x: max(
                outputExtent.minX,
                min(outputExtent.maxX - cropSize.width, anchorX - (anchorX - outputExtent.minX) / clampedZoom)
            ),
            y: max(
                outputExtent.minY,
                min(outputExtent.maxY - cropSize.height, anchorY - (anchorY - outputExtent.minY) / clampedZoom)
            )
        )
        let crop = CGRect(origin: origin, size: cropSize)

        return image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: clampedZoom, y: clampedZoom))
            .cropped(to: outputExtent)
    }

    private func applyImageOverlays(
        _ imagePaths: [String],
        over image: CIImage,
        outputExtent: CGRect
    ) -> CIImage {
        imagePaths.reduce(image.cropped(to: outputExtent)) { currentImage, imagePath in
            guard let overlayImage = cachedOverlayImage(for: imagePath) else {
                return currentImage
            }

            let normalizedOverlay = normalizeExtent(overlayImage)
            guard normalizedOverlay.extent.width > 0, normalizedOverlay.extent.height > 0 else {
                return currentImage
            }

            let scale = min(
                outputExtent.width / normalizedOverlay.extent.width,
                outputExtent.height / normalizedOverlay.extent.height
            )
            let scaledSize = CGSize(
                width: normalizedOverlay.extent.width * scale,
                height: normalizedOverlay.extent.height * scale
            )
            return normalizedOverlay
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: outputExtent.midX - scaledSize.width * 0.5,
                    y: outputExtent.midY - scaledSize.height * 0.5
                ))
                .composited(over: currentImage)
                .cropped(to: outputExtent)
        }
    }

    private func applyConfetti(
        _ bursts: [ConfettiBurst],
        over image: CIImage,
        outputExtent: CGRect,
        at time: CFTimeInterval
    ) -> CIImage {
        guard !bursts.isEmpty,
              let overlay = renderConfettiOverlay(bursts, outputExtent: outputExtent, at: time) else {
            return image.cropped(to: outputExtent)
        }

        return overlay
            .composited(over: image.cropped(to: outputExtent))
            .cropped(to: outputExtent)
    }

    private func applySpeechCaptionOverlay(
        over image: CIImage,
        outputExtent: CGRect,
        settings: ProcessingSettings
    ) -> CIImage {
        guard let overlay = cachedSpeechCaptionOverlayImage(settings: settings, size: outputExtent.size) else {
            return image.cropped(to: outputExtent)
        }

        return CIImage(cgImage: overlay)
            .composited(over: image.cropped(to: outputExtent))
            .cropped(to: outputExtent)
    }

    private func cachedSpeechCaptionOverlayImage(
        settings: ProcessingSettings,
        size: CGSize
    ) -> CGImage? {
        let key = SpeechCaptionOverlayCacheKey(
            text: settings.speechCaptionText ?? "",
            configuration: settings.speechCaptionConfiguration,
            size: size
        )

        speechCaptionOverlayLock.lock()
        if let image = speechCaptionOverlayCache, speechCaptionOverlayCacheKey == key {
            speechCaptionOverlayLock.unlock()
            return image
        }
        speechCaptionOverlayLock.unlock()

        guard let image = renderSpeechCaptionOverlayImage(settings: settings, size: size) else {
            return nil
        }

        speechCaptionOverlayLock.lock()
        speechCaptionOverlayCache = image
        speechCaptionOverlayCacheKey = key
        speechCaptionOverlayLock.unlock()

        return image
    }

    private func renderSpeechCaptionOverlayImage(
        settings: ProcessingSettings,
        size: CGSize
    ) -> CGImage? {
        guard hasSpeechCaption(settings),
              let pixelBuffer = makeSpeechCaptionOverlayPixelBuffer(size: size),
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let outputExtent = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(outputExtent)

        drawSpeechCaption(
            settings.speechCaptionText ?? "",
            configuration: settings.speechCaptionConfiguration,
            in: context,
            outputExtent: outputExtent
        )

        return context.makeImage()
    }

    private func drawSpeechCaption(
        _ text: String,
        configuration: CaptionRenderConfiguration,
        in context: CGContext,
        outputExtent: CGRect
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let outputWidth = outputExtent.width
        let outputHeight = outputExtent.height
        let outerInset = max(10, min(outputWidth, outputHeight) * 0.018)
        let padding = max(4, min(64, CGFloat(configuration.padding)))
        let availableWidth = max(1, outputWidth - outerInset * 2)
        let captionWidth = min(availableWidth, max(120, outputWidth * CGFloat(configuration.width.rawValue)))
        let textWidth = max(1, captionWidth - padding * 2)

        let paragraphStyle = NSMutableParagraphStyle()
        switch configuration.alignment {
        case .topLeft, .middleLeft, .bottomLeft:
            paragraphStyle.alignment = .left
        case .topCenter, .middleCenter, .bottomCenter:
            paragraphStyle.alignment = .center
        case .topRight, .middleRight, .bottomRight:
            paragraphStyle.alignment = .right
        }
        paragraphStyle.lineBreakMode = .byWordWrapping

        let fontSize = max(10, min(96, CGFloat(configuration.fontSize)))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: configuration.font.nsFont(size: fontSize),
            .foregroundColor: configuration.fontColor.nsColor,
            .paragraphStyle: paragraphStyle
        ]
        let attributedText = NSAttributedString(string: trimmedText, attributes: attributes)
        let measuredTextRect = attributedText.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let backgroundWidth = min(captionWidth, ceil(measuredTextRect.width + padding * 2))
        let backgroundHeight = ceil(measuredTextRect.height + padding * 2)
        let effectiveBackgroundHeight = min(backgroundHeight, max(1, outputHeight - outerInset * 2))
        let originX: CGFloat
        switch configuration.alignment {
        case .topLeft, .middleLeft, .bottomLeft:
            originX = outerInset
        case .topCenter, .middleCenter, .bottomCenter:
            originX = floor((outputWidth - backgroundWidth) * 0.5)
        case .topRight, .middleRight, .bottomRight:
            originX = outputWidth - backgroundWidth - outerInset
        }

        let originY: CGFloat
        switch configuration.alignment {
        case .topLeft, .topCenter, .topRight:
            originY = outputHeight - effectiveBackgroundHeight - outerInset
        case .middleLeft, .middleCenter, .middleRight:
            originY = floor((outputHeight - effectiveBackgroundHeight) * 0.5)
        case .bottomLeft, .bottomCenter, .bottomRight:
            originY = outerInset
        }

        let backgroundRect = NSRect(
            x: max(outerInset, min(outputWidth - backgroundWidth - outerInset, originX)),
            y: max(outerInset, min(outputHeight - effectiveBackgroundHeight - outerInset, originY)),
            width: backgroundWidth,
            height: effectiveBackgroundHeight
        )
        let textRect = backgroundRect.insetBy(dx: padding, dy: padding)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        configuration.backgroundColor.nsColor.setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8).fill()
        attributedText.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func drawSpeechCaption(
        to pixelBuffer: CVPixelBuffer,
        outputExtent: CGRect,
        settings: ProcessingSettings
    ) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return
        }

        guard let overlay = cachedSpeechCaptionOverlayImage(settings: settings, size: outputExtent.size) else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }

        if settings.outputFlipHorizontal || settings.outputFlipVertical {
            context.translateBy(
                x: settings.outputFlipHorizontal ? outputExtent.width : 0,
                y: settings.outputFlipVertical ? outputExtent.height : 0
            )
            context.scaleBy(
                x: settings.outputFlipHorizontal ? -1 : 1,
                y: settings.outputFlipVertical ? -1 : 1
            )
        }

        context.draw(overlay, in: outputExtent)
    }

    private func hasSpeechCaption(_ settings: ProcessingSettings) -> Bool {
        guard let text = settings.speechCaptionText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func renderConfettiOverlay(
        _ bursts: [ConfettiBurst],
        outputExtent: CGRect,
        at time: CFTimeInterval
    ) -> CIImage? {
        guard let pixelBuffer = makeConfettiOverlayPixelBuffer(size: outputExtent.size),
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        for burst in bursts {
            guard let progress = burst.progress(at: time) else {
                continue
            }

            drawConfettiBurst(
                burst,
                progress: progress,
                in: context,
                outputExtent: outputExtent
            )
        }

        return CIImage(cvPixelBuffer: pixelBuffer).cropped(to: outputExtent)
    }

    private func drawConfettiBurst(
        _ burst: ConfettiBurst,
        progress: CGFloat,
        in context: CGContext,
        outputExtent: CGRect
    ) {
        let width = outputExtent.width
        let height = outputExtent.height
        let resolutionScale = max(0.1, min(
            width / Self.confettiReferenceOutputSize.width,
            height / Self.confettiReferenceOutputSize.height
        ))

        for index in 0..<Self.confettiParticleCount {
            let delay = Self.confettiRandom(seed: burst.seed, index: index, salt: 0) * 0.22
            let localProgress = max(0, min(1, (progress - delay) / max(0.001, 1 - delay)))
            guard localProgress > 0 else { continue }

            let fadeIn = min(1, localProgress / 0.08)
            let fadeOut = min(1, (1 - localProgress) / 0.18)
            let alpha = fadeIn * fadeOut * 0.96
            guard alpha > 0.01 else { continue }

            let startX = outputExtent.minX + width * (
                0.5 + (Self.confettiRandom(seed: burst.seed, index: index, salt: 1) - 0.5) * 0.42
            )
            let laneSpread = width * (
                0.35 + Self.confettiRandom(seed: burst.seed, index: index, salt: 2) * 0.55
            )
            let drift = (
                Self.confettiRandom(seed: burst.seed, index: index, salt: 3) - 0.5
            ) * laneSpread * localProgress
            let phase = Self.confettiRandom(seed: burst.seed, index: index, salt: 4) * .pi * 2
            let sway = CGFloat(sin(Double(localProgress * 10 + phase))) * (
                12 + Self.confettiRandom(seed: burst.seed, index: index, salt: 5) * 24
            ) * resolutionScale
            let speed = 0.78 + Self.confettiRandom(seed: burst.seed, index: index, salt: 6) * 0.58
            let fall = CGFloat(pow(Double(localProgress), 1.22)) * (height + 190 * resolutionScale) * speed
            let x = startX + drift + sway
            let y = outputExtent.maxY + 80 * resolutionScale - fall

            guard y > outputExtent.minY - 40 * resolutionScale,
                  y < outputExtent.maxY + 100 * resolutionScale,
                  x > outputExtent.minX - 60 * resolutionScale,
                  x < outputExtent.maxX + 60 * resolutionScale else {
                continue
            }

            let particleWidth = (7 + Self.confettiRandom(seed: burst.seed, index: index, salt: 7) * 10)
                * Self.confettiParticleScale
                * resolutionScale
            let particleHeight = (3 + Self.confettiRandom(seed: burst.seed, index: index, salt: 8) * 8)
                * Self.confettiParticleScale
                * resolutionScale
            let spinDirection: CGFloat = Self.confettiRandom(seed: burst.seed, index: index, salt: 9) < 0.5 ? -1 : 1
            let angle = (
                Self.confettiRandom(seed: burst.seed, index: index, salt: 10) * .pi * 2
            ) + localProgress * (4 + Self.confettiRandom(seed: burst.seed, index: index, salt: 11) * 10) * spinDirection
            let color = Self.confettiPalette[
                Int(Self.confettiRandom(seed: burst.seed, index: index, salt: 12) * CGFloat(Self.confettiPalette.count))
                    % Self.confettiPalette.count
            ]

            context.saveGState()
            context.translateBy(x: x, y: y)
            context.rotate(by: angle)
            context.setFillColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: alpha
            )
            context.fill(CGRect(
                x: -particleWidth * 0.5,
                y: -particleHeight * 0.5,
                width: particleWidth,
                height: particleHeight
            ))
            context.restoreGState()
        }
    }

    private static func confettiRandom(seed: UInt64, index: Int, salt: UInt64) -> CGFloat {
        var value = seed
        value &+= UInt64(index) &* 0x9E37_79B9_7F4A_7C15
        value &+= salt &* 0xBF58_476D_1CE4_E5B9
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31

        return CGFloat(Double(value & 0xFFFF_FFFF) / Double(UInt32.max))
    }

    private func applyOutputFlips(
        to image: CIImage,
        outputExtent: CGRect,
        horizontal: Bool,
        vertical: Bool
    ) -> CIImage {
        let croppedImage = image.cropped(to: outputExtent)
        guard horizontal || vertical else {
            return croppedImage
        }

        let transform = CGAffineTransform(
            translationX: horizontal ? outputExtent.width : 0,
            y: vertical ? outputExtent.height : 0
        )
        .scaledBy(
            x: horizontal ? -1 : 1,
            y: vertical ? -1 : 1
        )

        return croppedImage
            .transformed(by: transform)
            .cropped(to: outputExtent)
    }

    private func applyNtscEffect(to pixelBuffer: CVPixelBuffer, preset: NtscPreset) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        let processingSize = NtscEffectFrameSizer.processingSize(width: width, height: height)
        guard let processingPixelBuffer = makeNtscPixelBuffer(
            width: processingSize.width,
            height: processingSize.height
        ) else {
            _ = applyNtscEffectInPlace(to: pixelBuffer, preset: preset)
            return
        }

        let scaleX = CGFloat(processingSize.width) / CGFloat(width)
        let scaleY = CGFloat(processingSize.height) / CGFloat(height)
        let processingExtent = CGRect(
            x: 0,
            y: 0,
            width: processingSize.width,
            height: processingSize.height
        )
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(
            sourceImage,
            to: processingPixelBuffer,
            bounds: processingExtent,
            colorSpace: colorSpace
        )

        guard applyNtscEffectInPlace(to: processingPixelBuffer, preset: preset) else {
            return
        }

        let outputExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let processedImage = CIImage(cvPixelBuffer: processingPixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: 1 / scaleX, y: 1 / scaleY))
        ciContext.render(
            processedImage,
            to: pixelBuffer,
            bounds: outputExtent,
            colorSpace: colorSpace
        )
    }

    private func applyNtscEffectInPlace(to pixelBuffer: CVPixelBuffer, preset: NtscPreset) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return false }

        let compactBytesPerRow = width * SharedFrameConfiguration.bytesPerPixel
        let frameByteCount = compactBytesPerRow * height
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sourceBytesPerRow == compactBytesPerRow else {
            return false
        }

        do {
            try applyNtscEffectBgrxInPlace(
                width: UInt32(width),
                height: UInt32(height),
                frameNum: ntscEffectFrameCounter,
                preset: preset.platformPreset,
                pixels: baseAddress,
                byteCount: frameByteCount
            )
            ntscEffectFrameCounter &+= 1
            didReportNtscEffectError = false
            return true
        } catch {
            ntscEffectFrameCounter &+= 1
            guard !didReportNtscEffectError else { return false }
            didReportNtscEffectError = true
            setStatus("NTSC effect failed: \(error.localizedDescription)")
            return false
        }
    }

    private func cachedOverlayImage(for imagePath: String) -> CIImage? {
        imageOverlayLock.lock()
        if let image = imageOverlayCache[imagePath] {
            imageOverlayLock.unlock()
            return image
        }
        imageOverlayLock.unlock()

        let url = URL(fileURLWithPath: imagePath)
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }

        imageOverlayLock.lock()
        imageOverlayCache[imagePath] = image
        imageOverlayLock.unlock()

        return image
    }

    private func upscale(mask: CIImage, to extent: CGRect, blurRadius: Double) -> CIImage {
        let normalizedMask = normalizeExtent(mask)
        let scaleX = extent.width / normalizedMask.extent.width
        let scaleY = extent.height / normalizedMask.extent.height
        let scaledMask = normalizedMask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        if blurRadius <= 0 {
            return scaledMask.cropped(to: extent)
        }

        return scaledMask
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
    }

    private func normalizeExtent(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
    }

    private func makeOutputPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let integralSize = CGSize(width: width, height: height)
        if outputPixelBufferPool == nil || outputPixelBufferPoolSize != integralSize {
            outputPixelBufferPool = Self.makePixelBufferPool(
                width: width,
                height: height,
                pixelFormat: SharedFrameConfiguration.pixelFormat
            )
            outputPixelBufferPoolSize = integralSize
        }

        guard let outputPixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool, &pixelBuffer)
        return pixelBuffer
    }

     private func makeNtscPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let integralSize = CGSize(width: width, height: height)
        if ntscPixelBufferPool == nil || ntscPixelBufferPoolSize != integralSize {
            ntscPixelBufferPool = Self.makePixelBufferPool(
                width: width,
                height: height,
                pixelFormat: SharedFrameConfiguration.pixelFormat
            )
            ntscPixelBufferPoolSize = integralSize
        }

        guard let ntscPixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, ntscPixelBufferPool, &pixelBuffer)
        return pixelBuffer
    }

    private func makeConfettiOverlayPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let integralSize = CGSize(width: width, height: height)
        if confettiOverlayPixelBufferPool == nil || confettiOverlayPixelBufferPoolSize != integralSize {
            confettiOverlayPixelBufferPool = Self.makePixelBufferPool(
                width: width,
                height: height,
                pixelFormat: SharedFrameConfiguration.pixelFormat
            )
            confettiOverlayPixelBufferPoolSize = integralSize
        }

        guard let confettiOverlayPixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, confettiOverlayPixelBufferPool, &pixelBuffer)
        return pixelBuffer
    }

    private func makeSpeechCaptionOverlayPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let integralSize = CGSize(width: width, height: height)
        if speechCaptionOverlayPixelBufferPool == nil || speechCaptionOverlayPixelBufferPoolSize != integralSize {
            speechCaptionOverlayPixelBufferPool = Self.makePixelBufferPool(
                width: width,
                height: height,
                pixelFormat: SharedFrameConfiguration.pixelFormat
            )
            speechCaptionOverlayPixelBufferPoolSize = integralSize
        }

        guard let speechCaptionOverlayPixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, speechCaptionOverlayPixelBufferPool, &pixelBuffer)
        return pixelBuffer
    }

     private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        let formatSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        if outputFormatDescription == nil || outputFormatDescriptionSize != formatSize {
            updateOutputFormatDescription(size: formatSize)
        }

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

    private func resetOutputResources(for frameSize: OutputFrameSize) {
        let size = CGSize(width: frameSize.width, height: frameSize.height)
        outputPixelBufferPool = Self.makePixelBufferPool(
            width: frameSize.width,
            height: frameSize.height,
            pixelFormat: SharedFrameConfiguration.pixelFormat
        )
        outputPixelBufferPoolSize = size
        updateOutputFormatDescription(size: size)

        backgroundRemover.resetResources()
        ntscPixelBufferPool = nil
        ntscPixelBufferPoolSize = .zero
        confettiOverlayPixelBufferPool = nil
        confettiOverlayPixelBufferPoolSize = .zero
        speechCaptionOverlayPixelBufferPool = nil
        speechCaptionOverlayPixelBufferPoolSize = .zero
        speechCaptionOverlayLock.lock()
        speechCaptionOverlayCache = nil
        speechCaptionOverlayCacheKey = nil
        speechCaptionOverlayLock.unlock()
    }

    private func updateOutputFormatDescription(size: CGSize) {
        outputFormatDescription = nil
        outputFormatDescriptionSize = .zero

        let width = Int32(size.width.rounded())
        let height = Int32(size.height.rounded())
        guard width > 0, height > 0 else { return }

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: SharedFrameConfiguration.pixelFormat,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &outputFormatDescription
        )
        outputFormatDescriptionSize = CGSize(width: Int(width), height: Int(height))
    }

    private static func makePixelBufferPool(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        bitmapCompatible: Bool = true
    ) -> CVPixelBufferPool? {
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

    private func currentSettings() -> ProcessingSettings {
        settingsQueue.sync { settings }
    }

    private func updateSettings(_ update: @escaping (inout ProcessingSettings) -> Void) {
        settingsQueue.async {
            update(&self.settings)
        }
    }

    private func currentRenderMask() -> CIImage? {
        backgroundRemover.currentRenderMask()
    }

    private func refreshCurrentRenderMask(blurRadius: Double, outputFrameSize: OutputFrameSize) {
        backgroundRemover.refreshRenderMask(
            outputSize: CGSize(width: outputFrameSize.width, height: outputFrameSize.height),
            blurRadius: blurRadius
        )
    }

    private func clearMask() {
        backgroundRemover.clear()
    }

    private func currentBackgroundMediaImage() -> CIImage? {
        backgroundMediaLock.lock()
        if let image = backgroundMediaImage {
            backgroundMediaLock.unlock()
            return image
        }

        let videoOutput = backgroundMediaVideoOutput
        let videoTransform = backgroundMediaVideoTransform
        let fallbackImage = latestBackgroundMediaVideoImage
        backgroundMediaLock.unlock()

        guard let videoOutput else {
            return nil
        }

        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        let shouldCopyFrame = videoOutput.hasNewPixelBuffer(forItemTime: itemTime) || fallbackImage == nil
        guard shouldCopyFrame else {
            return fallbackImage
        }

        var displayTime = CMTime.invalid
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &displayTime
        ) else {
            return fallbackImage
        }

        let image = normalizeExtent(CIImage(cvPixelBuffer: pixelBuffer).transformed(by: videoTransform))
        backgroundMediaLock.lock()
        latestBackgroundMediaVideoImage = image
        backgroundMediaLock.unlock()

        return image
    }

    private func currentWindowBackgroundFrame(at time: CFTimeInterval) -> WindowBackgroundFrameSnapshot? {
        backgroundLock.lock()
        defer { backgroundLock.unlock() }

        guard let pixelBuffer = latestWindowBackgroundPixelBuffer else {
            return nil
        }

        guard let fadeSourcePixelBuffer = windowBackgroundFadeSourcePixelBuffer,
              let fadeStartTime = windowBackgroundFadeStartTime,
              windowBackgroundFadeDuration > 0 else {
            return WindowBackgroundFrameSnapshot(
                pixelBuffer: pixelBuffer,
                fadeSourcePixelBuffer: nil,
                fadeProgress: 1
            )
        }

        let rawProgress = max(0, min(1, (time - fadeStartTime) / windowBackgroundFadeDuration))
        guard rawProgress < 1 else {
            windowBackgroundFadeSourcePixelBuffer = nil
            windowBackgroundFadeStartTime = nil
            windowBackgroundFadeDuration = 0
            return WindowBackgroundFrameSnapshot(
                pixelBuffer: pixelBuffer,
                fadeSourcePixelBuffer: nil,
                fadeProgress: 1
            )
        }

        let easedProgress = rawProgress * rawProgress * (3 - 2 * rawProgress)
        return WindowBackgroundFrameSnapshot(
            pixelBuffer: pixelBuffer,
            fadeSourcePixelBuffer: fadeSourcePixelBuffer,
            fadeProgress: easedProgress
        )
    }

    private func setLatestWindowBackgroundPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        backgroundLock.lock()
        latestWindowBackgroundPixelBuffer = pixelBuffer
        if shouldFadeNextWindowBackgroundFrame {
            if windowBackgroundFadeSourcePixelBuffer != nil {
                windowBackgroundFadeStartTime = CACurrentMediaTime()
                windowBackgroundFadeDuration = Self.windowBackgroundCycleFadeDuration
            } else {
                windowBackgroundFadeDuration = 0
            }
            shouldFadeNextWindowBackgroundFrame = false
        }
        backgroundLock.unlock()
    }

    private func clearLatestWindowBackgroundPixelBuffer() {
        backgroundLock.lock()
        latestWindowBackgroundPixelBuffer = nil
        windowBackgroundFadeSourcePixelBuffer = nil
        windowBackgroundFadeStartTime = nil
        windowBackgroundFadeDuration = 0
        shouldFadeNextWindowBackgroundFrame = false
        backgroundLock.unlock()
    }

    private func prepareWindowBackgroundCycleFade() {
        backgroundLock.lock()
        if let latestWindowBackgroundPixelBuffer {
            windowBackgroundFadeSourcePixelBuffer = latestWindowBackgroundPixelBuffer
            windowBackgroundFadeStartTime = nil
            windowBackgroundFadeDuration = Self.windowBackgroundCycleFadeDuration
            shouldFadeNextWindowBackgroundFrame = true
        } else {
            windowBackgroundFadeSourcePixelBuffer = nil
            windowBackgroundFadeStartTime = nil
            windowBackgroundFadeDuration = 0
            shouldFadeNextWindowBackgroundFrame = false
        }
        backgroundLock.unlock()
    }

    private func startActiveWindowBackgroundCapture(statusPrefix: String, animated: Bool = false) {
        guard let activeWindowBackgroundOption,
              let activeWindowBackgroundIndex else {
            selectedWindowBackgroundTitle = nil
            windowBackgroundStatusText = "Color background"
            return
        }

        let title = windowBackgroundTitle(
            for: activeWindowBackgroundOption,
            index: activeWindowBackgroundIndex,
            total: selectedWindowBackgroundOptions.count
        )
        selectedWindowBackgroundTitle = title
        windowBackgroundStatusText = "\(statusPrefix) \(title)"
        startWindowBackgroundCapture(
            window: activeWindowBackgroundOption.window,
            title: title,
            animated: animated
        )
    }

    private func startWindowBackgroundCapture(window: SCWindow, title: String, animated: Bool) {
        if animated {
            prepareWindowBackgroundCycleFade()
        } else {
            clearLatestWindowBackgroundPixelBuffer()
        }

        windowBackgroundStream.onFrame = { [weak self] pixelBuffer in
            self?.setLatestWindowBackgroundPixelBuffer(pixelBuffer)
        }
        windowBackgroundStream.onStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.selectedWindowBackgroundTitle = title
                self?.windowBackgroundStatusText = "Using \(title)"
            }
        }
        windowBackgroundStream.onStopped = { [weak self] error in
            guard let self else { return }
            self.clearLatestWindowBackgroundPixelBuffer()
            DispatchQueue.main.async {
                if let error {
                    self.selectedWindowBackgroundTitle = nil
                    self.windowBackgroundStatusText = error.localizedDescription
                }
            }
        }
        let frameSize = currentSettings().outputFrameSize
        windowBackgroundStream.start(
            window: window,
            maximumSize: CGSize(width: frameSize.width, height: frameSize.height),
            pixelFormat: SharedFrameConfiguration.pixelFormat
        )
    }

    private func windowBackgroundTitle(
        for option: WindowBackgroundOption,
        index: Int,
        total: Int
    ) -> String {
        guard total > 1 else {
            return option.displayTitle
        }

        return "\(option.displayTitle) (\(index + 1)/\(total))"
    }

    private static func deduplicatedWindowOptions(_ options: [WindowBackgroundOption]) -> [WindowBackgroundOption] {
        var seenWindowIDs = Set<CGWindowID>()
        return options.filter { option in
            seenWindowIDs.insert(option.id).inserted
        }
    }

    private func stopWindowBackgroundStream() {
        windowBackgroundStream.stop()
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
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        frameCounter += 1
        let settings = currentSettings()
        let shouldRefreshMask = !backgroundRemover.hasMask
            || frameCounter.isMultiple(of: UInt64(max(1, settings.maskReuseFrameCount + 1)))

        if settings.backgroundRemovalEnabled && shouldRefreshMask {
            scheduleSegmentation(for: pixelBuffer)
        }

        scheduleRender(
            pixelBuffer: pixelBuffer,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }
}
