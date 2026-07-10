import AVFoundation
import Combine
import Foundation

#if canImport(CTranscribe)
import CTranscribe
#endif

final class SpeechToTextInputLevel: ObservableObject {
    @Published private(set) var value = 0.0

    func update(_ level: Double) {
        value = max(0, min(1, level))
    }
}

final class SpeechToTextTranscriber: ObservableObject {
    @Published private(set) var transcribedText = ""
    @Published private(set) var statusText = "Speech model not loaded."
    @Published private(set) var modelStatusText = "Speech model not loaded."
    @Published private(set) var isTranscribing = false
    let inputLevel = SpeechToTextInputLevel()

    private let queue = DispatchQueue(label: "com.emyn.speech-to-text.transcriber")
    private lazy var audioCapture = SpeechToTextAudioCapture { [weak self] samples in
        self?.enqueueAudio(samples)
    } onLevel: { [weak self] level in
        DispatchQueue.main.async {
            self?.inputLevel.update(level)
        }
    } onStatus: { [weak self] status in
        DispatchQueue.main.async {
            self?.statusText = status
        }
    }

    private var desiredModel: SpeechToTextModelDescriptor?
    private var desiredMicrophoneID = ""
    private var desiredTranscriptionEnabled = false
    private var desiredStreamingEnabled = false
    private var loadedModelID: String?
    private var loadingModelID: String?
    private var loadGeneration = 0
    private let publicationLock = NSLock()
    private var publicationGeneration = 0

    #if canImport(CTranscribe)
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private static var didInitializeBackends = false
    #endif

    private var audioBuffer: [Float] = []
    private var streamPendingSamples: [Float] = []
    private var isCaptureEnabledOnQueue = false
    private var isStreamingModeOnQueue = false
    private var hasSpeechInBuffer = false
    private var silentSampleCount = 0
    private var lastPartialRunSampleCount = 0
    private var isRunInProgress = false
    private var isStreamActive = false

    private let sampleRate = 16_000
    private let voiceThreshold: Float = 0.012
    private let trimThreshold: Float = 0.006
    private let minimumSpeechSamples = 8_000
    private let partialIntervalSamples = 32_000
    private let streamFeedIntervalSamples = 1_280
    private let finalSilenceSamples = 11_200
    private let maximumBufferedSamples = 160_000

    func apply(
        model selectedModel: SpeechToTextModelDescriptor,
        microphoneID: String,
        isEnabled: Bool,
        usesStreaming: Bool
    ) {
        desiredModel = selectedModel
        desiredMicrophoneID = microphoneID
        desiredTranscriptionEnabled = isEnabled
        desiredStreamingEnabled = usesStreaming
        advancePublicationGeneration()

        queue.async { [weak self] in
            guard let self else { return }
            if self.isStreamingModeOnQueue != usesStreaming {
                self.resetStreamingSession()
                self.resetAudioBuffer()
            }

            self.isCaptureEnabledOnQueue = isEnabled
            self.isStreamingModeOnQueue = usesStreaming
            if !isEnabled {
                self.resetStreamingSession()
                self.resetAudioBuffer()
            }
        }

        ensureModelLoaded(selectedModel)

        if isEnabled {
            startCaptureIfReady()
        } else {
            stopTranscribing(clearText: true)
        }
    }

    func loadModelIfAvailable(_ selectedModel: SpeechToTextModelDescriptor) {
        desiredModel = selectedModel
        ensureModelLoaded(selectedModel)
    }

    func stopTranscribing(clearText: Bool) {
        audioCapture.stop()
        advancePublicationGeneration()
        queue.async { [weak self] in
            guard let self else { return }
            self.isCaptureEnabledOnQueue = false
            self.resetStreamingSession()
            self.resetAudioBuffer()
            self.isRunInProgress = false
        }

        DispatchQueue.main.async {
            self.isTranscribing = false
            self.inputLevel.update(0)
            if clearText {
                self.transcribedText = ""
            }

            if self.loadedModelID != nil {
                self.statusText = "Transcription off."
            }
        }
    }

    deinit {
        audioCapture.stop()
        queue.sync {
            freeCurrentModel()
        }
    }

    private func ensureModelLoaded(_ selectedModel: SpeechToTextModelDescriptor) {
        guard SpeechToTextConfiguration.isModelDownloaded(selectedModel) else {
            loadGeneration += 1
            loadingModelID = nil
            loadedModelID = nil
            audioCapture.stop()
            queue.async { [weak self] in
                self?.freeCurrentModel()
            }
            DispatchQueue.main.async {
                self.isTranscribing = false
                self.modelStatusText = "Download \(selectedModel.title) to enable transcription."
                self.statusText = self.modelStatusText
            }
            return
        }

        guard loadedModelID != selectedModel.id, loadingModelID != selectedModel.id else { return }

        loadGeneration += 1
        let generation = loadGeneration
        loadingModelID = selectedModel.id
        let shouldStartAfterLoad = desiredTranscriptionEnabled
        let microphoneID = desiredMicrophoneID

        DispatchQueue.main.async {
            self.modelStatusText = "Loading \(selectedModel.title)..."
            self.statusText = self.modelStatusText
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.freeCurrentModel()

            #if canImport(CTranscribe)
            let loadResult = self.loadModel(selectedModel)
            #else
            let loadResult: SpeechToTextModelLoadResult = .failure("CTranscribe is not linked.")
            #endif

            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.loadingModelID = nil

                switch loadResult {
                case .success(let details):
                    self.loadedModelID = selectedModel.id
                    self.modelStatusText = details
                    self.statusText = shouldStartAfterLoad ? "Starting transcription..." : "Transcription off."
                    if shouldStartAfterLoad {
                        self.desiredMicrophoneID = microphoneID
                        self.startCaptureIfReady()
                    }
                case .failure(let message):
                    self.loadedModelID = nil
                    self.isTranscribing = false
                    self.modelStatusText = message
                    self.statusText = message
                }
            }
        }
    }

    #if canImport(CTranscribe)
    private func loadModel(_ selectedModel: SpeechToTextModelDescriptor) -> SpeechToTextModelLoadResult {
        if !Self.didInitializeBackends {
            let backendStatus = transcribe_init_backends_default()
            guard backendStatus == TRANSCRIBE_OK else {
                return .failure("Could not initialize transcription backends: \(Self.statusString(backendStatus))")
            }
            Self.didInitializeBackends = true
        }

        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)

        var loadedModel: OpaquePointer?
        let loadStatus = selectedModel.selectedModelPath.withCString { path in
            transcribe_model_load_file(path, &loadParams, &loadedModel)
        }

        guard loadStatus == TRANSCRIBE_OK, let loadedModel else {
            return .failure("Could not load \(selectedModel.title): \(Self.statusString(loadStatus))")
        }

        var sessionParams = transcribe_session_params()
        transcribe_session_params_init(&sessionParams)

        var loadedSession: OpaquePointer?
        let sessionStatus = transcribe_session_init(loadedModel, &sessionParams, &loadedSession)
        guard sessionStatus == TRANSCRIBE_OK, let loadedSession else {
            transcribe_model_free(loadedModel)
            return .failure("Could not create transcription session: \(Self.statusString(sessionStatus))")
        }

        model = loadedModel
        session = loadedSession

        let backend = String(cString: transcribe_model_backend(loadedModel))
        return .success("\(selectedModel.title) loaded\(backend.isEmpty ? "." : " on \(backend).")")
    }
    #endif

    private func startCaptureIfReady() {
        guard desiredTranscriptionEnabled else { return }
        guard let desiredModel else { return }

        guard loadedModelID == desiredModel.id else {
            statusText = "Waiting for \(desiredModel.title) to load..."
            return
        }

        audioCapture.start(deviceID: desiredMicrophoneID)
        isTranscribing = true
        statusText = "Listening for speech..."
    }

    private func enqueueAudio(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        queue.async { [weak self] in
            guard let self, self.isCaptureEnabledOnQueue else { return }
            #if canImport(CTranscribe)
            guard self.session != nil else { return }
            #else
            return
            #endif

            let chunkLevel = Self.rmsLevel(samples)
            let hasVoice = chunkLevel > self.voiceThreshold

            if self.isStreamingModeOnQueue {
                self.enqueueStreamingAudio(samples, hasVoice: hasVoice)
                return
            }

            self.enqueueOfflineAudio(samples, hasVoice: hasVoice)
        }
    }

    private func enqueueOfflineAudio(_ samples: [Float], hasVoice: Bool) {
        audioBuffer.append(contentsOf: samples)
        if audioBuffer.count > maximumBufferedSamples {
            audioBuffer.removeFirst(audioBuffer.count - maximumBufferedSamples)
        }

        if hasVoice {
            hasSpeechInBuffer = true
            silentSampleCount = 0
        } else {
            silentSampleCount += samples.count
        }

        guard hasSpeechInBuffer,
              audioBuffer.count >= minimumSpeechSamples else {
            return
        }

        let shouldFinalize = silentSampleCount >= finalSilenceSamples
        let shouldRunPartial = audioBuffer.count - lastPartialRunSampleCount >= partialIntervalSamples

        if shouldFinalize {
            runTranscription(final: true)
        } else if shouldRunPartial {
            runTranscription(final: false)
        }
    }

    private func enqueueStreamingAudio(_ samples: [Float], hasVoice: Bool) {
        if !hasSpeechInBuffer, !hasVoice {
            return
        }

        if hasVoice {
            hasSpeechInBuffer = true
            silentSampleCount = 0
        } else {
            silentSampleCount += samples.count
        }

        guard hasSpeechInBuffer else { return }

        let generation = currentPublicationGeneration()
        streamPendingSamples.append(contentsOf: samples)
        if streamPendingSamples.count > maximumBufferedSamples {
            streamPendingSamples.removeFirst(streamPendingSamples.count - maximumBufferedSamples)
        }

        guard beginStreamingRunIfNeeded(generation: generation) else {
            resetAudioBuffer()
            return
        }

        while streamPendingSamples.count >= streamFeedIntervalSamples {
            let chunk = Array(streamPendingSamples.prefix(streamFeedIntervalSamples))
            streamPendingSamples.removeFirst(streamFeedIntervalSamples)
            guard feedStreamingAudio(chunk, final: false, generation: generation) else {
                resetAudioBuffer()
                return
            }
        }

        if silentSampleCount >= finalSilenceSamples {
            if !streamPendingSamples.isEmpty {
                let remainingSamples = streamPendingSamples
                streamPendingSamples.removeAll(keepingCapacity: true)
                guard feedStreamingAudio(remainingSamples, final: false, generation: generation) else {
                    resetAudioBuffer()
                    return
                }
            }

            finalizeStreamingRun(generation: generation)
            resetAudioBuffer()
        }
    }

    private func beginStreamingRunIfNeeded(generation: Int) -> Bool {
        #if canImport(CTranscribe)
        guard !isStreamActive else { return true }
        guard let session else { return false }

        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)

        var streamParams = transcribe_stream_params()
        transcribe_stream_params_init(&streamParams)

        let status = transcribe_stream_begin(session, &runParams, &streamParams)
        guard status == TRANSCRIBE_OK else {
            publishStreamingStatus(
                text: "",
                status: "Streaming failed to start: \(Self.statusString(status))",
                generation: generation
            )
            resetStreamingSession()
            return false
        }

        isStreamActive = true
        return true
        #else
        return false
        #endif
    }

    private func feedStreamingAudio(_ samples: [Float], final: Bool, generation: Int) -> Bool {
        #if canImport(CTranscribe)
        guard !samples.isEmpty, let session else { return true }

        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)

        let status = samples.withUnsafeBufferPointer { buffer in
            transcribe_stream_feed(session, buffer.baseAddress, Int32(buffer.count), &update)
        }

        guard status == TRANSCRIBE_OK else {
            publishStreamingStatus(
                text: currentStreamingText(),
                status: "Streaming failed: \(Self.statusString(status))",
                generation: generation
            )
            resetStreamingSession()
            return false
        }

        if update.result_changed || update.committed_changed || update.tentative_changed {
            publishStreamingStatus(
                text: currentStreamingText(),
                status: final ? "Transcribed speech." : "Streaming...",
                generation: generation
            )
        }

        return true
        #else
        return false
        #endif
    }

    private func finalizeStreamingRun(generation: Int) {
        #if canImport(CTranscribe)
        guard isStreamActive, let session else { return }

        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)

        let status = transcribe_stream_finalize(session, &update)
        let text = currentStreamingText()
        let statusText = status == TRANSCRIBE_OK
            ? "Transcribed speech."
            : "Streaming finalize failed: \(Self.statusString(status))"

        publishStreamingStatus(
            text: text,
            status: statusText,
            generation: generation
        )

        isStreamActive = false
        if status != TRANSCRIBE_OK {
            resetStreamingSession()
        }
        #endif
    }

    private func runTranscription(final: Bool) {
        guard !isRunInProgress else { return }

        let snapshot = Self.trimmedAudio(
            audioBuffer,
            sampleRate: sampleRate,
            threshold: trimThreshold
        )
        guard snapshot.count >= minimumSpeechSamples else {
            if final {
                resetAudioBuffer()
            }
            return
        }

        isRunInProgress = true
        let generation = currentPublicationGeneration()
        lastPartialRunSampleCount = audioBuffer.count

        #if canImport(CTranscribe)
        guard let session else {
            isRunInProgress = false
            return
        }

        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)

        let status = snapshot.withUnsafeBufferPointer { buffer in
            transcribe_run(session, buffer.baseAddress, Int32(buffer.count), &runParams)
        }

        let text: String
        if status == TRANSCRIBE_OK || status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || status == TRANSCRIBE_ERR_ABORTED {
            text = String(cString: transcribe_full_text(session))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }

        DispatchQueue.main.async {
            guard self.currentPublicationGeneration() == generation,
                  self.desiredTranscriptionEnabled else {
                return
            }

            if !text.isEmpty {
                self.transcribedText = text
            }

            if status == TRANSCRIBE_OK {
                self.statusText = final ? "Transcribed speech." : "Transcribing..."
            } else if status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || status == TRANSCRIBE_ERR_ABORTED {
                self.statusText = "Transcription partial: \(Self.statusString(status))"
            } else {
                self.statusText = "Transcription failed: \(Self.statusString(status))"
            }
        }
        #endif

        if final {
            resetAudioBuffer()
        }

        isRunInProgress = false
    }

    private func resetAudioBuffer() {
        audioBuffer.removeAll(keepingCapacity: true)
        streamPendingSamples.removeAll(keepingCapacity: true)
        hasSpeechInBuffer = false
        silentSampleCount = 0
        lastPartialRunSampleCount = 0
    }

    private func freeCurrentModel() {
        #if canImport(CTranscribe)
        resetStreamingSession()

        if let session {
            transcribe_session_free(session)
            self.session = nil
        }

        if let model {
            transcribe_model_free(model)
            self.model = nil
        }
        #endif

        resetAudioBuffer()
    }

    private func resetStreamingSession() {
        #if canImport(CTranscribe)
        if let session, isStreamActive {
            transcribe_stream_reset(session)
        }
        #endif

        isStreamActive = false
        streamPendingSamples.removeAll(keepingCapacity: true)
    }

    private func currentStreamingText() -> String {
        #if canImport(CTranscribe)
        guard let session else { return "" }

        var streamText = transcribe_stream_text()
        transcribe_stream_text_init(&streamText)

        let status = transcribe_stream_get_text(session, &streamText)
        guard status == TRANSCRIBE_OK else {
            return String(cString: transcribe_full_text(session))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let committedText = Self.string(
            from: streamText.committed_text,
            byteCount: streamText.committed_text_bytes
        )
        let tentativeText = Self.string(
            from: streamText.tentative_text,
            byteCount: streamText.tentative_text_bytes
        )
        let displayText = (committedText + tentativeText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !displayText.isEmpty {
            return displayText
        }

        return Self.string(
            from: streamText.full_text,
            byteCount: streamText.full_text_bytes
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return ""
        #endif
    }

    private func publishStreamingStatus(text: String, status: String, generation: Int) {
        DispatchQueue.main.async {
            guard self.currentPublicationGeneration() == generation,
                  self.desiredTranscriptionEnabled,
                  self.desiredStreamingEnabled else {
                return
            }

            if !text.isEmpty {
                self.transcribedText = text
            }

            self.statusText = status
        }
    }

    private func advancePublicationGeneration() {
        publicationLock.lock()
        publicationGeneration += 1
        publicationLock.unlock()
    }

    private func currentPublicationGeneration() -> Int {
        publicationLock.lock()
        let generation = publicationGeneration
        publicationLock.unlock()
        return generation
    }

    private static func trimmedAudio(_ samples: [Float], sampleRate: Int, threshold: Float) -> [Float] {
        guard let firstSpeechIndex = samples.firstIndex(where: { abs($0) >= threshold }),
              let lastSpeechIndex = samples.lastIndex(where: { abs($0) >= threshold }) else {
            return []
        }

        let padding = Int(Double(sampleRate) * 0.18)
        let start = max(0, firstSpeechIndex - padding)
        let end = min(samples.count - 1, lastSpeechIndex + padding)
        guard start <= end else { return [] }
        return Array(samples[start...end])
    }

    private static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { partialResult, sample in
            partialResult + sample * sample
        }
        return sqrt(sumSquares / Float(samples.count))
    }

    #if canImport(CTranscribe)
    private static func string(from pointer: UnsafePointer<CChar>?, byteCount: UInt64) -> String {
        guard let pointer, byteCount > 0, byteCount <= UInt64(Int.max) else { return "" }
        let buffer = UnsafeRawBufferPointer(start: pointer, count: Int(byteCount))
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func statusString(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
    #endif
}

private enum SpeechToTextModelLoadResult {
    case success(String)
    case failure(String)
}

private extension SpeechToTextModelDescriptor {
    var selectedModelPath: String {
        SpeechToTextConfiguration.localModelURL(for: self).path
    }
}

private final class SpeechToTextAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onSamples: ([Float]) -> Void
    private let onLevel: (Double) -> Void
    private let onStatus: (String) -> Void
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.emyn.speech-to-text.capture.session")
    private let sampleQueue = DispatchQueue(label: "com.emyn.speech-to-text.capture.samples")
    private let levelPublishIntervalNanoseconds: UInt64 = 50_000_000
    private var activeDeviceID = ""
    private var resampler = SpeechToTextLinearResampler()
    private var lastLevelPublication = DispatchTime(uptimeNanoseconds: 0)

    init(
        onSamples: @escaping ([Float]) -> Void,
        onLevel: @escaping (Double) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.onStatus = onStatus
        super.init()

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    func start(deviceID: String) {
        activeDeviceID = deviceID

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureAndStart(deviceID: deviceID)
        case .notDetermined:
            onStatus("Requesting microphone access...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart(deviceID: self.activeDeviceID)
                    } else {
                        self.onStatus("Microphone access was denied.")
                    }
                }
            }
        case .denied:
            onStatus("Microphone access is denied in System Settings.")
        case .restricted:
            onStatus("Microphone access is restricted.")
        @unknown default:
            onStatus("Microphone access is unavailable.")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.resampler.reset()
            DispatchQueue.main.async {
                self.onLevel(0)
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let extracted = Self.floatSamples(from: sampleBuffer) else { return }

        let samples = resampler.process(
            extracted.samples,
            sourceSampleRate: extracted.sampleRate,
            targetSampleRate: 16_000
        )
        guard !samples.isEmpty else { return }

        publishLevel(Self.meterLevel(samples))
        onSamples(samples)
    }

    private func publishLevel(_ level: Double) {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastLevelPublication.uptimeNanoseconds >= levelPublishIntervalNanoseconds else {
            return
        }

        lastLevelPublication = now
        onLevel(level)
    }

    private func configureAndStart(deviceID: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard let device = Self.device(for: deviceID) else {
                DispatchQueue.main.async {
                    self.onStatus("Selected microphone is unavailable.")
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        self.onStatus("Could not use selected microphone.")
                    }
                    return
                }

                self.session.addInput(input)

                guard self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        self.onStatus("Could not read microphone audio.")
                    }
                    return
                }

                self.output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                self.session.addOutput(self.output)
                self.session.commitConfiguration()

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                self.resampler.reset()
                DispatchQueue.main.async {
                    self.onStatus("Listening on \(device.localizedName)...")
                }
            } catch {
                DispatchQueue.main.async {
                    self.onStatus("Could not start microphone: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func device(for deviceID: String) -> AVCaptureDevice? {
        if !deviceID.isEmpty {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            if let selectedDevice = session.devices.first(where: { $0.uniqueID == deviceID }) {
                return selectedDevice
            }
        }

        return AVCaptureDevice.default(for: .audio)
    }

    private static func floatSamples(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = streamDescription.pointee
        let sampleRate = asbd.mSampleRate
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        var neededSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )

        guard neededSize > 0 else { return nil }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: neededSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawBufferList.deallocate()
        }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: neededSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return nil }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let bytesPerSample = max(1, bitsPerChannel / 8)
        var samples = [Float]()
        samples.reserveCapacity(frameCount)

        if isNonInterleaved, buffers.count >= channelCount {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    guard let data = buffers[channel].mData else { continue }
                    sum += sampleValue(
                        from: data,
                        sampleIndex: frame,
                        bytesPerSample: bytesPerSample,
                        isFloat: isFloat,
                        bitsPerChannel: bitsPerChannel
                    )
                }
                samples.append(sum / Float(channelCount))
            }
        } else {
            guard let data = buffers[0].mData else { return nil }
            let totalSamples = frameCount * channelCount
            guard Int(buffers[0].mDataByteSize) >= totalSamples * bytesPerSample else { return nil }

            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += sampleValue(
                        from: data,
                        sampleIndex: frame * channelCount + channel,
                        bytesPerSample: bytesPerSample,
                        isFloat: isFloat,
                        bitsPerChannel: bitsPerChannel
                    )
                }
                samples.append(sum / Float(channelCount))
            }
        }

        return (samples, sampleRate)
    }

    private static func sampleValue(
        from data: UnsafeMutableRawPointer,
        sampleIndex: Int,
        bytesPerSample: Int,
        isFloat: Bool,
        bitsPerChannel: Int
    ) -> Float {
        let pointer = data.advanced(by: sampleIndex * bytesPerSample)

        if isFloat, bitsPerChannel == 32 {
            return pointer.assumingMemoryBound(to: Float.self).pointee
        }

        if bitsPerChannel == 16 {
            return Float(pointer.assumingMemoryBound(to: Int16.self).pointee) / Float(Int16.max)
        }

        if bitsPerChannel == 32 {
            return Float(pointer.assumingMemoryBound(to: Int32.self).pointee) / Float(Int32.max)
        }

        return 0
    }

    private static func meterLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { partialResult, sample in
            partialResult + sample * sample
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        return Double(max(0, min(1, (decibels + 55) / 55)))
    }
}

private struct SpeechToTextLinearResampler {
    private var inputSampleRate = 16_000.0
    private var position = 0.0
    private var lastSample: Float?

    mutating func reset() {
        inputSampleRate = 16_000
        position = 0
        lastSample = nil
    }

    mutating func process(
        _ input: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard !input.isEmpty else { return [] }

        guard abs(sourceSampleRate - targetSampleRate) > 0.5 else {
            lastSample = input.last
            position = 0
            inputSampleRate = sourceSampleRate
            return input
        }

        if abs(sourceSampleRate - inputSampleRate) > 0.5 {
            inputSampleRate = sourceSampleRate
            position = 0
            lastSample = nil
        }

        let source: [Float]
        if let lastSample {
            source = [lastSample] + input
        } else {
            source = input
        }

        guard source.count > 1 else {
            lastSample = input.last
            return []
        }

        let step = sourceSampleRate / targetSampleRate
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 2)

        while position + 1 < Double(source.count) {
            let lowerIndex = Int(position)
            let fraction = Float(position - Double(lowerIndex))
            let lower = source[lowerIndex]
            let upper = source[lowerIndex + 1]
            output.append(lower + (upper - lower) * fraction)
            position += step
        }

        position -= Double(source.count - 1)
        lastSample = input.last
        return output
    }
}
