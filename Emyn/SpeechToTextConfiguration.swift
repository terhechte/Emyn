import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

struct SpeechToTextMicrophoneDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
}

struct SpeechToTextModelDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let repository: String
    let filename: String
    let byteSize: Int64

    var downloadURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/main/\(filename)"
        return components.url!
    }

    var sizeTitle: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var localFilename: String {
        if Self.builtIn.contains(where: { $0.repository == repository && $0.filename == filename }) {
            return filename.replacingOccurrences(of: "/", with: "__")
        }

        let sanitizedRepository = repository.replacingOccurrences(of: "/", with: "__")
        let sanitizedFilename = filename.replacingOccurrences(of: "/", with: "__")
        return "\(sanitizedRepository)__\(sanitizedFilename)"
    }

    static let builtIn: [SpeechToTextModelDescriptor] = [
        SpeechToTextModelDescriptor(
            id: "whisper-tiny-en-q4",
            title: "Whisper Tiny EN Q4",
            detail: "Fast English model for lightweight captions.",
            repository: "handy-computer/whisper-tiny.en-gguf",
            filename: "whisper-tiny.en-Q4_K_M.gguf",
            byteSize: 43_545_248
        ),
        SpeechToTextModelDescriptor(
            id: "whisper-tiny-en-q8",
            title: "Whisper Tiny EN Q8",
            detail: "Fast English model with higher quantization quality.",
            repository: "handy-computer/whisper-tiny.en-gguf",
            filename: "whisper-tiny.en-Q8_0.gguf",
            byteSize: 45_904_544
        ),
        SpeechToTextModelDescriptor(
            id: "whisper-base-en-q4",
            title: "Whisper Base EN Q4",
            detail: "Balanced English model for better accuracy.",
            repository: "handy-computer/whisper-base.en-gguf",
            filename: "whisper-base.en-Q4_K_M.gguf",
            byteSize: 58_794_272
        ),
        SpeechToTextModelDescriptor(
            id: "whisper-base-en-q8",
            title: "Whisper Base EN Q8",
            detail: "Balanced English model with higher quantization quality.",
            repository: "handy-computer/whisper-base.en-gguf",
            filename: "whisper-base.en-Q8_0.gguf",
            byteSize: 84_886_208
        ),
        SpeechToTextModelDescriptor(
            id: "canary-180m-flash-q4",
            title: "Canary 180M Flash Q4",
            detail: "Multilingual EN, DE, ES, FR speech-to-text model.",
            repository: "handy-computer/canary-180m-flash-gguf",
            filename: "canary-180m-flash-Q4_K_M.gguf",
            byteSize: 139_223_744
        ),
        SpeechToTextModelDescriptor(
            id: "parakeet-tdt-06b-v2-q4",
            title: "Parakeet TDT 0.6B Q4",
            detail: "Higher-accuracy English model for local transcription.",
            repository: "handy-computer/parakeet-tdt-0.6b-v2-gguf",
            filename: "parakeet-tdt-0.6b-v2-Q4_K_M.gguf",
            byteSize: 475_491_840
        )
    ]

    static func descriptor(
        for id: String,
        in availableModels: [SpeechToTextModelDescriptor] = builtIn
    ) -> SpeechToTextModelDescriptor {
        availableModels.first { $0.id == id }
            ?? builtIn.first { $0.id == id }
            ?? builtIn[0]
    }

    static func catalogDescriptor(
        repository: String,
        filename: String,
        byteSize: Int64
    ) -> SpeechToTextModelDescriptor? {
        guard filename.hasSuffix(".gguf") else { return nil }

        return SpeechToTextModelDescriptor(
            id: legacyID(repository: repository, filename: filename)
                ?? "\(repository)/\(filename)",
            title: catalogTitle(repository: repository, filename: filename),
            detail: catalogDetail(repository: repository, filename: filename),
            repository: repository,
            filename: filename,
            byteSize: byteSize
        )
    }

    private static func legacyID(repository: String, filename: String) -> String? {
        let key = "\(repository)|\(filename)"
        let legacyIDs = Dictionary(
            uniqueKeysWithValues: builtIn.map { ("\($0.repository)|\($0.filename)", $0.id) }
        )
        return legacyIDs[key]
    }

    private static func catalogTitle(repository: String, filename: String) -> String {
        let repositoryName = repository.split(separator: "/").last.map(String.init) ?? repository
        let baseName = filename.replacingOccurrences(of: ".gguf", with: "")
        let quantization = quantizationName(from: baseName)
        let modelName = repositoryName
            .replacingOccurrences(of: "-gguf", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".en", with: " EN")
            .capitalized

        guard let quantization else { return modelName }
        return "\(modelName) \(quantization)"
    }

    private static func catalogDetail(repository: String, filename: String) -> String {
        let family = repository
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: "-gguf", with: "")
            ?? repository
        let quantization = quantizationName(from: filename) ?? "GGUF"
        return "\(family) \(quantization) model from the transcribe.cpp catalog."
    }

    private static func quantizationName(from text: String) -> String? {
        let knownQuantizations = ["Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "F16", "F32"]
        return knownQuantizations.first { text.contains($0) }
    }
}

enum SpeechToTextCaptionFont: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        switch self {
        case .system:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .rounded:
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
                .withDesign(.rounded) ?? NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .serif:
            return NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    func swiftUIFont(size: CGFloat) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: .semibold)
        case .rounded:
            return .system(size: size, weight: .semibold, design: .rounded)
        case .serif:
            return .system(size: size, weight: .semibold, design: .serif)
        case .monospaced:
            return .system(size: size, weight: .semibold, design: .monospaced)
        }
    }
}

enum SpeechToTextCaptionWidth: Double, CaseIterable, Identifiable {
    case full = 1.0
    case eighty = 0.8
    case twoThirds = 0.66
    case half = 0.5

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .full: return "100%"
        case .eighty: return "80%"
        case .twoThirds: return "66%"
        case .half: return "50%"
        }
    }
}

enum SpeechToTextCaptionAlignment: String, CaseIterable, Identifiable {
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

    var swiftUIAlignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .middleLeft: return .leading
        case .middleCenter: return .center
        case .middleRight: return .trailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: return .leading
        case .topCenter, .middleCenter, .bottomCenter: return .center
        case .topRight, .middleRight, .bottomRight: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: return .leading
        case .topCenter, .middleCenter, .bottomCenter: return .center
        case .topRight, .middleRight, .bottomRight: return .trailing
        }
    }
}

struct SpeechToTextColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        red = Double(color.redComponent)
        green = Double(color.greenComponent)
        blue = Double(color.blueComponent)
        alpha = Double(color.alphaComponent)
    }

    init(color: Color) {
        self.init(nsColor: NSColor(color))
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: max(0, min(1, red)),
            green: max(0, min(1, green)),
            blue: max(0, min(1, blue)),
            alpha: max(0, min(1, alpha))
        )
    }

    var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }

    static let white = SpeechToTextColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let translucentBlack = SpeechToTextColor(red: 0, green: 0, blue: 0, alpha: 0.72)
}

struct SpeechToTextCaptionRenderConfiguration: Equatable {
    var font: SpeechToTextCaptionFont
    var fontSize: Double
    var fontColor: SpeechToTextColor
    var backgroundColor: SpeechToTextColor
    var width: SpeechToTextCaptionWidth
    var padding: Double
    var alignment: SpeechToTextCaptionAlignment
    var isAffectedByNTSC: Bool

    static let defaultValue = SpeechToTextCaptionRenderConfiguration(
        font: .system,
        fontSize: 30,
        fontColor: .white,
        backgroundColor: .translucentBlack,
        width: .eighty,
        padding: 14,
        alignment: .bottomCenter,
        isAffectedByNTSC: false
    )
}

@MainActor
final class SpeechToTextConfiguration: ObservableObject {
    @Published private(set) var availableModels = SpeechToTextModelDescriptor.builtIn

    @Published var isSpeechToTextEnabled: Bool {
        didSet { defaults.set(isSpeechToTextEnabled, forKey: Key.enabled) }
    }

    @Published var selectedModelID: String {
        didSet { defaults.set(selectedModelID, forKey: Key.selectedModelID) }
    }

    @Published var selectedMicrophoneID: String {
        didSet { defaults.set(selectedMicrophoneID, forKey: Key.selectedMicrophoneID) }
    }

    @Published var captionFont: SpeechToTextCaptionFont {
        didSet { defaults.set(captionFont.rawValue, forKey: Key.captionFont) }
    }

    @Published var captionFontSize: Double {
        didSet { defaults.set(Self.clampedFontSize(captionFontSize), forKey: Key.captionFontSize) }
    }

    @Published var captionFontColor: SpeechToTextColor {
        didSet { saveColor(captionFontColor, forKey: Key.captionFontColor) }
    }

    @Published var captionBackgroundColor: SpeechToTextColor {
        didSet { saveColor(captionBackgroundColor, forKey: Key.captionBackgroundColor) }
    }

    @Published var captionWidth: SpeechToTextCaptionWidth {
        didSet { defaults.set(captionWidth.rawValue, forKey: Key.captionWidth) }
    }

    @Published var captionPadding: Double {
        didSet { defaults.set(Self.clampedPadding(captionPadding), forKey: Key.captionPadding) }
    }

    @Published var captionAlignment: SpeechToTextCaptionAlignment {
        didSet { defaults.set(captionAlignment.rawValue, forKey: Key.captionAlignment) }
    }

    @Published var areCaptionsAffectedByNTSC: Bool {
        didSet { defaults.set(areCaptionsAffectedByNTSC, forKey: Key.captionsAffectedByNTSC) }
    }

    private let defaults: UserDefaults

    var selectedModel: SpeechToTextModelDescriptor {
        SpeechToTextModelDescriptor.descriptor(for: selectedModelID, in: availableModels)
    }

    var selectedModelLocalURL: URL {
        Self.localModelURL(for: selectedModel)
    }

    var captionRenderConfiguration: SpeechToTextCaptionRenderConfiguration {
        SpeechToTextCaptionRenderConfiguration(
            font: captionFont,
            fontSize: captionFontSize,
            fontColor: captionFontColor,
            backgroundColor: captionBackgroundColor,
            width: captionWidth,
            padding: captionPadding,
            alignment: captionAlignment,
            isAffectedByNTSC: areCaptionsAffectedByNTSC
        )
    }

    var backendStatusText: String {
        #if canImport(TranscribeCpp)
        return "TranscribeCpp is linked. The selected GGUF path is ready."
        #elseif canImport(CTranscribe)
        return "CTranscribe is linked. The selected GGUF path is ready."
        #else
        return "TranscribeCpp is not linked yet. The selected GGUF path is persisted for the backend."
        #endif
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSpeechToTextEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? false

        let storedModelID = defaults.string(forKey: Key.selectedModelID)
        if let storedModelID, !storedModelID.isEmpty {
            selectedModelID = storedModelID
        } else {
            selectedModelID = SpeechToTextModelDescriptor.builtIn[0].id
        }

        selectedMicrophoneID = defaults.string(forKey: Key.selectedMicrophoneID) ?? ""

        captionFont = defaults.string(forKey: Key.captionFont)
            .flatMap(SpeechToTextCaptionFont.init(rawValue:)) ?? .system
        captionFontSize = Self.clampedFontSize(defaults.object(forKey: Key.captionFontSize) as? Double ?? 30)
        captionFontColor = Self.loadColor(forKey: Key.captionFontColor, from: defaults) ?? .white
        captionBackgroundColor = Self.loadColor(forKey: Key.captionBackgroundColor, from: defaults) ?? .translucentBlack

        let storedWidth = defaults.object(forKey: Key.captionWidth) as? Double
        captionWidth = storedWidth.flatMap(SpeechToTextCaptionWidth.init(rawValue:)) ?? .eighty

        captionPadding = Self.clampedPadding(defaults.object(forKey: Key.captionPadding) as? Double ?? 14)
        captionAlignment = defaults.string(forKey: Key.captionAlignment)
            .flatMap(SpeechToTextCaptionAlignment.init(rawValue:)) ?? .bottomCenter
        areCaptionsAffectedByNTSC = defaults.object(forKey: Key.captionsAffectedByNTSC) as? Bool ?? false
    }

    func replaceAvailableModels(_ models: [SpeechToTextModelDescriptor]) {
        let nextModels = models.isEmpty ? SpeechToTextModelDescriptor.builtIn : models
        availableModels = nextModels

        guard nextModels.contains(where: { $0.id == selectedModelID }) else {
            selectedModelID = nextModels[0].id
            return
        }
    }

    func localModelPathForBackend() -> String? {
        let url = selectedModelLocalURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    nonisolated static func modelsDirectory() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        return baseURL
            .appendingPathComponent("Emyn", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
    }

    nonisolated static func localModelURL(for model: SpeechToTextModelDescriptor) -> URL {
        modelsDirectory().appendingPathComponent(model.localFilename, isDirectory: false)
    }

    nonisolated static func isModelDownloaded(_ model: SpeechToTextModelDescriptor) -> Bool {
        let url = localModelURL(for: model)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }

        return size.int64Value == model.byteSize
    }

    private func saveColor(_ color: SpeechToTextColor, forKey key: String) {
        guard let data = try? JSONEncoder().encode(color) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadColor(forKey key: String, from defaults: UserDefaults) -> SpeechToTextColor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SpeechToTextColor.self, from: data)
    }

    private static func clampedFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return 30 }
        return max(14, min(56, value))
    }

    private static func clampedPadding(_ value: Double) -> Double {
        guard value.isFinite else { return 14 }
        return max(4, min(48, value))
    }

    private enum Key {
        static let enabled = "speechToText.enabled.v1"
        static let selectedModelID = "speechToText.selectedModelID.v1"
        static let selectedMicrophoneID = "speechToText.selectedMicrophoneID.v1"
        static let captionFont = "speechToText.captionFont.v1"
        static let captionFontSize = "speechToText.captionFontSize.v1"
        static let captionFontColor = "speechToText.captionFontColor.v1"
        static let captionBackgroundColor = "speechToText.captionBackgroundColor.v1"
        static let captionWidth = "speechToText.captionWidth.v1"
        static let captionPadding = "speechToText.captionPadding.v1"
        static let captionAlignment = "speechToText.captionAlignment.v1"
        static let captionsAffectedByNTSC = "speechToText.captionsAffectedByNTSC.v1"
    }
}

@MainActor
final class SpeechToTextModelCatalog: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusText = "Using bundled model catalog."

    private var hasLoadedRemoteCatalog = false

    func refreshIfNeeded(configuration: SpeechToTextConfiguration) {
        guard !hasLoadedRemoteCatalog else { return }
        refresh(configuration: configuration)
    }

    func refresh(configuration: SpeechToTextConfiguration) {
        guard !isRefreshing else { return }

        isRefreshing = true
        statusText = "Loading transcribe.cpp model catalog..."

        Task {
            do {
                let models = try await Self.fetchCatalog()
                configuration.replaceAvailableModels(models)
                hasLoadedRemoteCatalog = true
                statusText = "Loaded \(models.count) model variants from Hugging Face."
            } catch {
                statusText = "Using bundled catalog: \(error.localizedDescription)"
            }

            isRefreshing = false
        }
    }

    nonisolated private static func fetchCatalog() async throws -> [SpeechToTextModelDescriptor] {
        let summaries: [HuggingFaceModelSummary] = try await fetchJSON(from: catalogURL)
        let repositories = summaries.compactMap(\.repositoryID)

        var modelsByIndex = Array(repeating: [SpeechToTextModelDescriptor](), count: repositories.count)
        var firstError: Error?

        await withTaskGroup(of: (Int, Result<[SpeechToTextModelDescriptor], Error>).self) { group in
            for (index, repository) in repositories.enumerated() {
                group.addTask {
                    do {
                        let models = try await fetchRepositoryModels(repository: repository)
                        return (index, .success(models))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            for await (index, result) in group {
                switch result {
                case .success(let models):
                    modelsByIndex[index] = models
                case .failure(let error):
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }

        var seenModelIDs = Set<String>()
        let models = modelsByIndex
            .flatMap { $0 }
            .filter { seenModelIDs.insert($0.id).inserted }

        guard !models.isEmpty else {
            throw firstError ?? CatalogError.noModels
        }

        return models
    }

    nonisolated private static func fetchRepositoryModels(
        repository: String
    ) async throws -> [SpeechToTextModelDescriptor] {
        let detail: HuggingFaceModelDetail = try await fetchJSON(from: detailURL(for: repository))
        let resolvedRepository = detail.repositoryID ?? repository

        return detail.siblings
            .compactMap { sibling -> SpeechToTextModelDescriptor? in
                guard let byteSize = sibling.byteSize else { return nil }
                return SpeechToTextModelDescriptor.catalogDescriptor(
                    repository: resolvedRepository,
                    filename: sibling.rfilename,
                    byteSize: byteSize
                )
            }
    }

    nonisolated private static func fetchJSON<Value: Decodable>(from url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.setValue("Emyn", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CatalogError.invalidResponse(url)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CatalogError.httpStatus(httpResponse.statusCode, url)
        }

        return try JSONDecoder().decode(Value.self, from: data)
    }

    nonisolated private static var catalogURL: URL {
        URL(string: "https://huggingface.co/api/models?author=handy-computer&filter=transcribe.cpp&sort=downloads&direction=-1&limit=200")!
    }

    nonisolated private static func detailURL(for repository: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(repository)"
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        return components.url!
    }

    private struct HuggingFaceModelSummary: Decodable {
        let id: String?
        let modelId: String?

        var repositoryID: String? {
            Self.normalizedRepositoryID(modelId ?? id)
        }

        private static func normalizedRepositoryID(_ value: String?) -> String? {
            guard let value, value.contains("/") else { return nil }
            return value.replacingOccurrences(of: "https://huggingface.co/", with: "")
        }
    }

    private struct HuggingFaceModelDetail: Decodable {
        let id: String?
        let modelId: String?
        let siblings: [HuggingFaceSibling]

        var repositoryID: String? {
            Self.normalizedRepositoryID(modelId ?? id)
        }

        private static func normalizedRepositoryID(_ value: String?) -> String? {
            guard let value, value.contains("/") else { return nil }
            return value.replacingOccurrences(of: "https://huggingface.co/", with: "")
        }
    }

    private struct HuggingFaceSibling: Decodable {
        let rfilename: String
        let size: Int64?
        let lfs: HuggingFaceLFS?

        var byteSize: Int64? {
            lfs?.size ?? size
        }
    }

    private struct HuggingFaceLFS: Decodable {
        let size: Int64?
    }

    private enum CatalogError: LocalizedError {
        case invalidResponse(URL)
        case httpStatus(Int, URL)
        case noModels

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let url):
                return "Invalid response from \(url.host ?? url.absoluteString)."
            case .httpStatus(let statusCode, let url):
                return "\(url.host ?? url.absoluteString) returned HTTP \(statusCode)."
            case .noModels:
                return "No GGUF models were found."
            }
        }
    }
}

final class SpeechToTextMicrophoneMonitor: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published private(set) var microphones: [SpeechToTextMicrophoneDescriptor] = []
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var statusText = "Select a microphone to test live input."

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.emyn.speech-to-text.microphone.session")
    private let sampleQueue = DispatchQueue(label: "com.emyn.speech-to-text.microphone.samples")
    private var activeDeviceID = ""
    private var lastLevelPublishTime = Date.distantPast.timeIntervalSinceReferenceDate

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        refreshDevices()
    }

    func refreshDevices() {
        let discoveredMicrophones = Self.discoverMicrophones()
        DispatchQueue.main.async {
            self.microphones = discoveredMicrophones
            if discoveredMicrophones.isEmpty {
                self.statusText = "No microphones were found."
            }
        }
    }

    func startMonitoring(deviceID: String) {
        activeDeviceID = deviceID
        refreshDevices()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureAndStart(deviceID: deviceID)
        case .notDetermined:
            statusText = "Requesting microphone access..."
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart(deviceID: self.activeDeviceID)
                    } else {
                        self.inputLevel = 0
                        self.isMonitoring = false
                        self.statusText = "Microphone access was denied."
                    }
                }
            }
        case .denied:
            inputLevel = 0
            isMonitoring = false
            statusText = "Microphone access is denied in System Settings."
        case .restricted:
            inputLevel = 0
            isMonitoring = false
            statusText = "Microphone access is restricted."
        @unknown default:
            inputLevel = 0
            isMonitoring = false
            statusText = "Microphone access is unavailable."
        }
    }

    func stopMonitoring() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }

            DispatchQueue.main.async {
                self.inputLevel = 0
                self.isMonitoring = false
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let level = Self.level(from: sampleBuffer) else { return }

        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastLevelPublishTime > 0.05 else { return }
        lastLevelPublishTime = now

        DispatchQueue.main.async {
            let decayedLevel = self.inputLevel * 0.72
            self.inputLevel = max(level, decayedLevel)
        }
    }

    private func configureAndStart(deviceID: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard let device = Self.device(for: deviceID) else {
                DispatchQueue.main.async {
                    self.inputLevel = 0
                    self.isMonitoring = false
                    self.statusText = "Selected microphone is not available."
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }

                guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        self.inputLevel = 0
                        self.isMonitoring = false
                        self.statusText = "Could not connect to \(device.localizedName)."
                    }
                    return
                }

                self.session.addInput(input)
                self.output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                self.session.addOutput(self.output)
                self.session.commitConfiguration()

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                DispatchQueue.main.async {
                    self.isMonitoring = true
                    self.statusText = "Monitoring \(device.localizedName)."
                }
            } catch {
                DispatchQueue.main.async {
                    self.inputLevel = 0
                    self.isMonitoring = false
                    self.statusText = "Could not open microphone: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func discoverMicrophones() -> [SpeechToTextMicrophoneDescriptor] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = session.devices

        return devices
            .map { SpeechToTextMicrophoneDescriptor(id: $0.uniqueID, title: $0.localizedName) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func device(for deviceID: String) -> AVCaptureDevice? {
        if !deviceID.isEmpty {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            )

            if let matchingDevice = session.devices.first(where: { $0.uniqueID == deviceID }) {
                return matchingDevice
            }
        }

        return AVCaptureDevice.default(for: .audio)
    }

    private static func level(from sampleBuffer: CMSampleBuffer) -> Double? {
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
           let level = level(from: blockBuffer) {
            return level
        }

        return levelFromAudioBufferList(sampleBuffer)
    }

    private static func level(from blockBuffer: CMBlockBuffer) -> Double? {
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr,
              let dataPointer,
              totalLength >= MemoryLayout<Int16>.size else {
            return nil
        }

        let measurement = measureInt16Samples(data: dataPointer, byteCount: totalLength)
        return normalizedLevel(sumOfSquares: measurement.sumOfSquares, measuredSamples: measurement.measuredSamples)
    }

    private static func levelFromAudioBufferList(_ sampleBuffer: CMSampleBuffer) -> Double? {
        var requiredSize = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )

        guard requiredSize > 0 else { return nil }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )

        guard status == noErr else { return nil }

        var sumOfSquares = 0.0
        var measuredSamples = 0

        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }

            let measurement = measureInt16Samples(data: data, byteCount: Int(buffer.mDataByteSize))
            sumOfSquares += measurement.sumOfSquares
            measuredSamples += measurement.measuredSamples
        }

        return normalizedLevel(sumOfSquares: sumOfSquares, measuredSamples: measuredSamples)
    }

    private static func measureInt16Samples(data: UnsafeRawPointer, byteCount: Int) -> (sumOfSquares: Double, measuredSamples: Int) {
        guard byteCount >= MemoryLayout<Int16>.size else {
            return (0, 0)
        }

        let dataPointer = data.assumingMemoryBound(to: Int16.self)
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        let step = max(1, sampleCount / 512)
        var sumOfSquares = 0.0
        var measuredSamples = 0

        for index in Swift.stride(from: 0, to: sampleCount, by: step) {
            let sample = Double(dataPointer[index]) / Double(Int16.max)
            sumOfSquares += sample * sample
            measuredSamples += 1
        }

        return (sumOfSquares, measuredSamples)
    }

    private static func normalizedLevel(sumOfSquares: Double, measuredSamples: Int) -> Double? {
        guard measuredSamples > 0 else { return 0 }

        let rms = sqrt(sumOfSquares / Double(measuredSamples))
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        return max(0, min(1, (decibels + 55) / 55))
    }
}

@MainActor
final class SpeechToTextModelDownloader: ObservableObject {
    @Published private(set) var activeModelID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = "Models are saved in Application Support."

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    var isDownloading: Bool {
        activeModelID != nil
    }

    func isModelDownloaded(_ model: SpeechToTextModelDescriptor) -> Bool {
        SpeechToTextConfiguration.isModelDownloaded(model)
    }

    func download(_ model: SpeechToTextModelDescriptor) {
        if isModelDownloaded(model) {
            statusText = "\(model.title) is already downloaded."
            return
        }

        cancel()
        activeModelID = model.id
        progress = 0
        statusText = "Downloading \(model.title)..."

        let task = URLSession.shared.downloadTask(with: model.downloadURL) { tempURL, response, error in
            let result = Self.installDownloadedModel(
                tempURL: tempURL,
                response: response,
                error: error,
                model: model
            )

            Task { @MainActor in
                self.completeDownload(result, model: model)
            }
        }

        progressObservation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fractionCompleted = progress.fractionCompleted
            guard let downloader = self else { return }
            Task { @MainActor in
                downloader.progress = fractionCompleted.isFinite ? fractionCompleted : 0
            }
        }

        downloadTask = task
        task.resume()
    }

    func deleteDownloadedModel(_ model: SpeechToTextModelDescriptor) {
        do {
            try FileManager.default.removeItem(at: SpeechToTextConfiguration.localModelURL(for: model))
            statusText = "Removed \(model.title)."
        } catch CocoaError.fileNoSuchFile {
            statusText = "\(model.title) was not downloaded."
        } catch {
            statusText = "Could not remove model: \(error.localizedDescription)"
        }
    }

    func revealDownloadedModel(_ model: SpeechToTextModelDescriptor) {
        let url = SpeechToTextConfiguration.localModelURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusText = "\(model.title) is not downloaded."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        progressObservation = nil

        if activeModelID != nil {
            activeModelID = nil
            progress = 0
            statusText = "Download cancelled."
        }
    }

    private func completeDownload(_ result: Result<URL, Error>, model: SpeechToTextModelDescriptor) {
        progressObservation = nil
        downloadTask = nil
        activeModelID = nil

        switch result {
        case .success(let url):
            progress = 1
            statusText = "Downloaded \(model.title) to \(url.lastPathComponent)."
        case .failure(let error):
            progress = 0
            if (error as NSError).code == NSURLErrorCancelled {
                statusText = "Download cancelled."
            } else {
                statusText = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func installDownloadedModel(
        tempURL: URL?,
        response: URLResponse?,
        error: Error?,
        model: SpeechToTextModelDescriptor
    ) -> Result<URL, Error> {
        if let error {
            return .failure(error)
        }

        guard let tempURL else {
            return .failure(DownloadError.missingTemporaryFile)
        }

        let destinationURL = SpeechToTextConfiguration.localModelURL(for: model)

        do {
            try FileManager.default.createDirectory(
                at: SpeechToTextConfiguration.modelsDirectory(),
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            guard SpeechToTextConfiguration.isModelDownloaded(model) else {
                let receivedBytes = fileSize(at: destinationURL)
                try? FileManager.default.removeItem(at: destinationURL)
                return .failure(DownloadError.invalidSize(expected: model.byteSize, received: receivedBytes))
            }

            return .success(destinationURL)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }

        return size.int64Value
    }

    private enum DownloadError: LocalizedError {
        case missingTemporaryFile
        case invalidSize(expected: Int64, received: Int64)

        var errorDescription: String? {
            switch self {
            case .missingTemporaryFile:
                return "The downloaded model file was not available."
            case .invalidSize(let expected, let received):
                let expectedTitle = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                let receivedTitle = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                return "Downloaded size was \(receivedTitle), expected \(expectedTitle)."
            }
        }
    }
}
