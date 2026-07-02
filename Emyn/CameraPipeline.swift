import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import PlatformMacOSKit
import QuartzCore
import ScreenCaptureKit
import UniformTypeIdentifiers
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
    case media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replacement: return "Color"
        case .blur: return "Blur"
        case .media: return "Media"
        }
    }
}

enum BackgroundMediaFit: String, CaseIterable, Identifiable {
    case fill
    case contain
    case scale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: return "Fill"
        case .contain: return "Contain"
        case .scale: return "Scale"
        }
    }
}

enum BackgroundContentAlignment: String, CaseIterable, Identifiable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case middleCenter
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .middleCenter: return "Middle Center"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }

    func origin(for contentSize: CGSize, in outputExtent: CGRect) -> CGPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .middleLeft, .bottomLeft:
            x = outputExtent.minX
        case .topCenter, .middleCenter, .bottomCenter:
            x = outputExtent.midX - contentSize.width * 0.5
        case .topRight, .middleRight, .bottomRight:
            x = outputExtent.maxX - contentSize.width
        }

        let y: CGFloat
        switch self {
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = outputExtent.minY
        case .middleLeft, .middleCenter, .middleRight:
            y = outputExtent.midY - contentSize.height * 0.5
        case .topLeft, .topCenter, .topRight:
            y = outputExtent.maxY - contentSize.height
        }

        return CGPoint(x: x, y: y)
    }
}

enum BackgroundMediaKind {
    case image
    case video

    var title: String {
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

enum NtscPreset: String, CaseIterable, Identifiable {
    case low
    case medium
    case hard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }

    var platformPreset: PlatformMacOSKit.NtscEffectPreset {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .hard: return .hard
        }
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
    var backgroundMediaFit: BackgroundMediaFit = .fill
    var backgroundMediaAlignment: BackgroundContentAlignment = .middleCenter
    var windowBackgroundFit: BackgroundMediaFit = .fill
    var windowBackgroundAlignment: BackgroundContentAlignment = .middleCenter
    var outputFlipHorizontal = false
    var outputFlipVertical = false
    var ntscEffectEnabled = false
    var ntscPreset: NtscPreset = .medium
    var presentationEffects = PresentationEffects()
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
        didSet {
            updateSettings { $0.backgroundMode = self.backgroundMode }
            updateBackgroundMediaPlaybackState()
        }
    }

    @Published var backgroundBlurRadius: Double = 18 {
        didSet { updateSettings { $0.backgroundBlurRadius = self.backgroundBlurRadius } }
    }

    @Published var backgroundPreset: BackgroundPreset = .black {
        didSet { updateSettings { $0.background = self.backgroundPreset } }
    }

    @Published var backgroundMediaFit: BackgroundMediaFit = .fill {
        didSet { updateSettings { $0.backgroundMediaFit = self.backgroundMediaFit } }
    }

    @Published var backgroundMediaAlignment: BackgroundContentAlignment = .middleCenter {
        didSet { updateSettings { $0.backgroundMediaAlignment = self.backgroundMediaAlignment } }
    }

    @Published var windowBackgroundFit: BackgroundMediaFit = .fill {
        didSet { updateSettings { $0.windowBackgroundFit = self.windowBackgroundFit } }
    }

    @Published var windowBackgroundAlignment: BackgroundContentAlignment = .middleCenter {
        didSet { updateSettings { $0.windowBackgroundAlignment = self.windowBackgroundAlignment } }
    }

    @Published var outputFlipHorizontal = false {
        didSet { updateSettings { $0.outputFlipHorizontal = self.outputFlipHorizontal } }
    }

    @Published var outputFlipVertical = false {
        didSet { updateSettings { $0.outputFlipVertical = self.outputFlipVertical } }
    }

    @Published var ntscEffectEnabled = false {
        didSet { updateSettings { $0.ntscEffectEnabled = self.ntscEffectEnabled } }
    }

    @Published var ntscPreset: NtscPreset = .medium {
        didSet { updateSettings { $0.ntscPreset = self.ntscPreset } }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var measuredFramesPerSecond: Double = 0
    @Published private(set) var selectedWindowBackgroundTitle: String?
    @Published private(set) var selectedWindowBackgroundOptions: [WindowBackgroundOption] = []
    @Published private(set) var activeWindowBackgroundIndex: Int?
    @Published private(set) var windowBackgroundStatusText = "Color background"
    @Published private(set) var selectedBackgroundMediaTitle: String?
    @Published private(set) var selectedBackgroundMediaKind: BackgroundMediaKind?
    @Published private(set) var backgroundMediaStatusText = "No media selected"

    var previewHandler: ((CMSampleBuffer) -> Void)?

    var hasWindowBackgroundSelection: Bool {
        !selectedWindowBackgroundOptions.isEmpty
    }

    var hasBackgroundMediaSelection: Bool {
        selectedBackgroundMediaKind != nil
    }

    var activeWindowBackgroundOption: WindowBackgroundOption? {
        guard let activeWindowBackgroundIndex,
              selectedWindowBackgroundOptions.indices.contains(activeWindowBackgroundIndex) else {
            return nil
        }

        return selectedWindowBackgroundOptions[activeWindowBackgroundIndex]
    }

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
    private let backgroundMediaLock = NSLock()
    private let imageOverlayLock = NSLock()

    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let segmentationRequest = VNGeneratePersonSegmentationRequest()
    private let frameWriter: SharedFrameWriter?
    private static let screenCaptureBackgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
    private static let confettiParticleCount = 144
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
    private var latestMask: CIImage?
    private var outputPixelBufferPool: CVPixelBufferPool?
    private var analysisPixelBufferPool: CVPixelBufferPool?
    private var analysisPixelBufferPoolSize = CGSize(width: 0, height: 0)
    private var outputFormatDescription: CMFormatDescription?
    private var frameCounter: UInt64 = 0
    private var segmentationInFlight = false
    private var renderInFlight = false
    private var renderedFrameCounter = 0
    private var ntscEffectFrameCounter: UInt64 = 0
    private var didReportNtscEffectError = false
    private var lastFPSUpdate = CACurrentMediaTime()
    private var windowBackgroundStream: SCStream?
    private var latestWindowBackgroundPixelBuffer: CVPixelBuffer?
    private var backgroundMediaImage: CIImage?
    private var backgroundMediaPlayer: AVPlayer?
    private var backgroundMediaVideoOutput: AVPlayerItemVideoOutput?
    private var backgroundMediaVideoTransform: CGAffineTransform = .identity
    private var latestBackgroundMediaVideoImage: CIImage?
    private var backgroundMediaLoopObserver: NSObjectProtocol?
    private var imageOverlayCache: [String: CIImage] = [:]

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

    deinit {
        clearBackgroundMediaResources()
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

    func selectBackgroundMedia(url: URL) {
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
            backgroundMode = .media
        } catch {
            backgroundMediaStatusText = error.localizedDescription
            setStatus("Background media failed: \(error.localizedDescription)")
        }
    }

    func clearBackgroundMedia() {
        clearBackgroundMediaResources()
        selectedBackgroundMediaTitle = nil
        selectedBackgroundMediaKind = nil
        backgroundMediaStatusText = "No media selected"

        if backgroundMode == .media {
            backgroundMode = .replacement
        }
    }

    func selectWindowBackground(_ option: WindowBackgroundOption) {
        selectWindowBackgrounds([option])
    }

    func selectWindowBackgrounds(_ options: [WindowBackgroundOption]) {
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

    func clearWindowBackground() {
        selectedWindowBackgroundTitle = nil
        selectedWindowBackgroundOptions = []
        activeWindowBackgroundIndex = nil
        windowBackgroundStatusText = "Color background"
        clearLatestWindowBackgroundPixelBuffer()

        screenCaptureQueue.async {
            self.stopWindowBackgroundStream()
        }
    }

    @discardableResult
    func cycleWindowBackground() -> WindowBackgroundOption? {
        guard selectedWindowBackgroundOptions.count > 1 else {
            return activeWindowBackgroundOption
        }

        let currentIndex = activeWindowBackgroundIndex ?? 0
        activeWindowBackgroundIndex = selectedWindowBackgroundOptions.index(after: currentIndex)
        if activeWindowBackgroundIndex == selectedWindowBackgroundOptions.endIndex {
            activeWindowBackgroundIndex = selectedWindowBackgroundOptions.startIndex
        }

        startActiveWindowBackgroundCapture(statusPrefix: "Switching to")
        return activeWindowBackgroundOption
    }

    func setWindowBackgroundVisible(_ isVisible: Bool, animated: Bool) {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.setWindowBackgroundVisible(isVisible, animated: animated, at: now)
        }
    }

    func toggleWindowBackgroundVisibility() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.toggleWindowBackgroundVisibility(at: now)
        }
    }

    func togglePersonCompactPosition() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.togglePersonPosition(at: now)
        }
    }

    func toggleWindowAndCompactPerson() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.toggleWindowAndPersonPresentation(at: now)
        }
    }

    func toggleWindowZoom() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.toggleWindowZoom(at: now)
        }
    }

    func setWindowZoomCenter(_ center: CGPoint?) {
        let clampedCenter = CGPoint(
            x: max(0, min(1, center?.x ?? 0.5)),
            y: max(0, min(1, center?.y ?? 0.5))
        )
        updateSettings { settings in
            settings.presentationEffects.windowZoomCenter = clampedCenter
        }
    }

    func toggleImageOverlay(identifier: String, imagePath: String) {
        updateSettings { settings in
            if settings.presentationEffects.activeImageOverlayPathsByID[identifier] == nil {
                settings.presentationEffects.activeImageOverlayPathsByID[identifier] = imagePath
            } else {
                settings.presentationEffects.activeImageOverlayPathsByID.removeValue(forKey: identifier)
            }
        }
    }

    func triggerConfetti() {
        let now = CACurrentMediaTime()
        updateSettings { settings in
            settings.presentationEffects.triggerConfetti(at: now)
        }
    }

    func toggleNtscEffect() {
        ntscEffectEnabled.toggle()
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
                    self.updateBackgroundMediaPlaybackState()
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
        setBackgroundMediaPlayback(shouldPlay: isRunning && backgroundMode == .media)
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
        let renderTime = CACurrentMediaTime()
        let effects = settings.presentationEffects.resolved(at: renderTime)

        var renderedImage: CIImage
        if let mask = currentMask() {
            let upscaledMask = upscale(mask: mask, to: outputExtent)
            let background = backgroundImage(
                settings: settings,
                effects: effects,
                foreground: foreground,
                outputExtent: outputExtent
            )

            renderedImage = composePerson(
                foreground: foreground,
                mask: upscaledMask,
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
        outputExtent: CGRect
    ) -> CIImage {
        let baseBackground = baseBackgroundImage(
            settings: settings,
            foreground: foreground,
            outputExtent: outputExtent
        )

        guard let pixelBuffer = currentWindowBackgroundPixelBuffer() else {
            return baseBackground
        }

        let opacity = max(0, min(1, effects.windowBackgroundOpacity))
        guard opacity > 0.001 else {
            return baseBackground
        }

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

    private func baseBackgroundImage(
        settings: ProcessingSettings,
        foreground: CIImage,
        outputExtent: CGRect
    ) -> CIImage {
        switch settings.backgroundMode {
        case .blur:
            let radius = max(0, settings.backgroundBlurRadius)
            return foreground
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: outputExtent)
        case .media:
            let backing = solidBackgroundImage(settings: settings, outputExtent: outputExtent)
            guard let mediaImage = currentBackgroundMediaImage() else {
                return backing
            }

            return fittedMediaBackgroundImage(
                mediaImage,
                fit: settings.backgroundMediaFit,
                alignment: settings.backgroundMediaAlignment,
                outputExtent: outputExtent,
                backing: backing
            )
        case .replacement:
            return solidBackgroundImage(settings: settings, outputExtent: outputExtent)
        }
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
        guard !bursts.isEmpty else {
            return image.cropped(to: outputExtent)
        }

        return bursts.reduce(image.cropped(to: outputExtent)) { currentImage, burst in
            guard let progress = burst.progress(at: time) else {
                return currentImage
            }

            return applyConfettiBurst(
                burst,
                progress: progress,
                over: currentImage,
                outputExtent: outputExtent
            )
        }
    }

    private func applyConfettiBurst(
        _ burst: ConfettiBurst,
        progress: CGFloat,
        over image: CIImage,
        outputExtent: CGRect
    ) -> CIImage {
        var renderedImage = image.cropped(to: outputExtent)
        let width = outputExtent.width
        let height = outputExtent.height

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
            )
            let speed = 0.78 + Self.confettiRandom(seed: burst.seed, index: index, salt: 6) * 0.58
            let fall = CGFloat(pow(Double(localProgress), 1.22)) * (height + 190) * speed
            let x = startX + drift + sway
            let y = outputExtent.maxY + 80 - fall

            guard y > outputExtent.minY - 40,
                  y < outputExtent.maxY + 100,
                  x > outputExtent.minX - 60,
                  x < outputExtent.maxX + 60 else {
                continue
            }

            let particleWidth = (7 + Self.confettiRandom(seed: burst.seed, index: index, salt: 7) * 10)
                * Self.confettiParticleScale
            let particleHeight = (3 + Self.confettiRandom(seed: burst.seed, index: index, salt: 8) * 8)
                * Self.confettiParticleScale
            let spinDirection: CGFloat = Self.confettiRandom(seed: burst.seed, index: index, salt: 9) < 0.5 ? -1 : 1
            let angle = (
                Self.confettiRandom(seed: burst.seed, index: index, salt: 10) * .pi * 2
            ) + localProgress * (4 + Self.confettiRandom(seed: burst.seed, index: index, salt: 11) * 10) * spinDirection
            let color = Self.confettiPalette[
                Int(Self.confettiRandom(seed: burst.seed, index: index, salt: 12) * CGFloat(Self.confettiPalette.count))
                    % Self.confettiPalette.count
            ]
            let particle = CIImage(color: CIColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: alpha
            ))
            .cropped(to: CGRect(
                x: -particleWidth * 0.5,
                y: -particleHeight * 0.5,
                width: particleWidth,
                height: particleHeight
            ))
            .transformed(by: CGAffineTransform(translationX: x, y: y).rotated(by: angle))

            renderedImage = particle.composited(over: renderedImage)
        }

        return renderedImage.cropped(to: outputExtent)
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

        let compactBytesPerRow = width * SharedFrameConfiguration.bytesPerPixel
        let frameByteCount = compactBytesPerRow * height
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sourceBytesPerRow >= compactBytesPerRow else {
            return
        }

        var frameData = Data(count: frameByteCount)
        frameData.withUnsafeMutableBytes { destination in
            guard let destinationBaseAddress = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBaseAddress.advanced(by: row * compactBytesPerRow),
                    baseAddress.advanced(by: row * sourceBytesPerRow),
                    compactBytesPerRow
                )
            }
        }

        do {
            let processedData = try applyNtscEffectBgrx(
                width: UInt32(width),
                height: UInt32(height),
                frameNum: ntscEffectFrameCounter,
                preset: preset.platformPreset,
                pixels: frameData
            )
            ntscEffectFrameCounter &+= 1
            didReportNtscEffectError = false
            guard processedData.count == frameByteCount else { return }

            processedData.withUnsafeBytes { source in
                guard let sourceBaseAddress = source.baseAddress else { return }
                for row in 0..<height {
                    memcpy(
                        baseAddress.advanced(by: row * sourceBytesPerRow),
                        sourceBaseAddress.advanced(by: row * compactBytesPerRow),
                        compactBytesPerRow
                    )
                }
            }
        } catch {
            ntscEffectFrameCounter &+= 1
            guard !didReportNtscEffectError else { return }
            didReportNtscEffectError = true
            setStatus("NTSC effect failed: \(error.localizedDescription)")
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

    private func startActiveWindowBackgroundCapture(statusPrefix: String) {
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
        startWindowBackgroundCapture(window: activeWindowBackgroundOption.window, title: title)
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
        configuration.shouldBeOpaque = false
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
