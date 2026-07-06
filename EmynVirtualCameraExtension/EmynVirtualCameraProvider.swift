import CoreMediaIO
import CoreVideo
import Darwin
import Foundation
import IOKit.audio
import os.log

private let extensionFrameRate: Int32 = 30

private enum VirtualCameraIDs {
    static let device = UUID(uuidString: "D6E4CDE1-4078-4F85-A968-026C3F247344")!
    static let stream = UUID(uuidString: "6D4E197E-13C2-44EF-A7B3-453DFE0E7936")!
    static let legacyDevice = "com.stylemac.Emyn.VirtualCamera"
}

final class EmynVirtualCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private var streamSource: EmynVirtualCameraStreamSource!
    private var streamingCounter: UInt32 = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(
        label: "com.stylemac.Emyn.VirtualCameraExtension.timer",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )

    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private let bufferAuxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: 6]
    private var frameReader: SharedFrameReader?
    private var lastGoodPixelBuffer: CVPixelBuffer?
    private var fallbackPhase = 0
    private var outputFrameSize = SharedFrameConfiguration.outputFrameSize

    init(localizedName: String) {
        super.init()
        frameReader = try? SharedFrameReader()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: VirtualCameraIDs.device,
            legacyDeviceID: VirtualCameraIDs.legacyDevice,
            source: self
        )

        configureVideoOutput(for: outputFrameSize)

        let streamFormats = OutputFrameSize.allCases.map(Self.makeStreamFormat)
        streamSource = EmynVirtualCameraStreamSource(
            localizedName: "Emyn Virtual Camera Video",
            streamID: VirtualCameraIDs.stream,
            streamFormats: streamFormats,
            activeFormatIndex: Self.formatIndex(for: outputFrameSize),
            device: device
        )

        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Emyn Background Removal"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
    }

    func startStreaming() {
        guard bufferPool != nil else { return }

        streamingCounter += 1
        if streamingCounter > 1 {
            return
        }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(extensionFrameRate), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            self?.sendFrame()
        }
        timer.resume()
        self.timer = timer
    }

    func stopStreaming() {
        if streamingCounter > 1 {
            streamingCounter -= 1
            return
        }

        streamingCounter = 0
        timer?.cancel()
        timer = nil
    }

    func setOutputFrameSize(_ frameSize: OutputFrameSize) {
        SharedFrameConfiguration.outputFrameSize = frameSize
        applyOutputFrameSizeIfNeeded(frameSize, notifyStream: false)
    }

    private func sendFrame() {
        let changedFormat = applyOutputFrameSizeIfNeeded(
            SharedFrameConfiguration.outputFrameSize,
            notifyStream: true
        )

        var pixelBuffer: CVPixelBuffer?
        let allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            bufferPool,
            bufferAuxAttributes,
            &pixelBuffer
        )

        guard allocationStatus == kCVReturnSuccess, let pixelBuffer else {
            os_log(.error, "Could not allocate virtual camera pixel buffer: %{public}d", allocationStatus)
            return
        }

        if frameReader == nil {
            frameReader = try? SharedFrameReader()
        }

        if frameReader?.copyLatestFrame(to: pixelBuffer) != nil {
            lastGoodPixelBuffer = pixelBuffer
        } else if !copyLastGoodFrame(to: pixelBuffer) {
            drawFallbackFrame(into: pixelBuffer)
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: extensionFrameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: videoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            os_log(.error, "Could not create virtual camera sample buffer: %{public}d", sampleStatus)
            return
        }

        let hostTime = UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        streamSource.stream.send(
            sampleBuffer,
            discontinuity: changedFormat ? .unknown : [],
            hostTimeInNanoseconds: hostTime
        )
    }

    @discardableResult
    private func applyOutputFrameSizeIfNeeded(
        _ frameSize: OutputFrameSize,
        notifyStream: Bool
    ) -> Bool {
        guard outputFrameSize != frameSize || bufferPool == nil || videoDescription == nil else {
            return false
        }

        configureVideoOutput(for: frameSize)
        streamSource?.setActiveFormatIndex(Self.formatIndex(for: frameSize), notify: notifyStream)
        return true
    }

    private func configureVideoOutput(for frameSize: OutputFrameSize) {
        outputFrameSize = frameSize
        fallbackPhase = 0

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: SharedFrameConfiguration.pixelFormat,
            width: Int32(frameSize.width),
            height: Int32(frameSize.height),
            extensions: nil,
            formatDescriptionOut: &videoDescription
        )

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: frameSize.width,
            kCVPixelBufferHeightKey: frameSize.height,
            kCVPixelBufferPixelFormatTypeKey: SharedFrameConfiguration.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &bufferPool)
    }

    private func copyLastGoodFrame(to pixelBuffer: CVPixelBuffer) -> Bool {
        guard let lastGoodPixelBuffer else {
            return false
        }

        return copyPixelBuffer(from: lastGoodPixelBuffer, to: pixelBuffer)
    }

    private func copyPixelBuffer(from sourcePixelBuffer: CVPixelBuffer, to destinationPixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(sourcePixelBuffer) == CVPixelBufferGetPixelFormatType(destinationPixelBuffer) else {
            return false
        }

        CVPixelBufferLockBaseAddress(sourcePixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(destinationPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destinationPixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(sourcePixelBuffer, .readOnly)
        }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourcePixelBuffer),
              let destinationBaseAddress = CVPixelBufferGetBaseAddress(destinationPixelBuffer) else {
            return false
        }

        let sourceWidth = CVPixelBufferGetWidth(sourcePixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourcePixelBuffer)
        let destinationWidth = CVPixelBufferGetWidth(destinationPixelBuffer)
        let destinationHeight = CVPixelBufferGetHeight(destinationPixelBuffer)
        let height = CVPixelBufferGetHeight(sourcePixelBuffer)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(sourcePixelBuffer)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destinationPixelBuffer)

        if sourceWidth == destinationWidth, sourceHeight == destinationHeight {
            let copyBytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)

            for row in 0..<height {
                memcpy(
                    destinationBaseAddress.advanced(by: row * destinationBytesPerRow),
                    sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
                    copyBytesPerRow
                )
            }

            return true
        }

        scalePixelBuffer(
            from: sourceBaseAddress,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceBytesPerRow: sourceBytesPerRow,
            to: destinationBaseAddress,
            destinationWidth: destinationWidth,
            destinationHeight: destinationHeight,
            destinationBytesPerRow: destinationBytesPerRow
        )

        return true
    }

    private func scalePixelBuffer(
        from sourceBaseAddress: UnsafeMutableRawPointer,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceBytesPerRow: Int,
        to destinationBaseAddress: UnsafeMutableRawPointer,
        destinationWidth: Int,
        destinationHeight: Int,
        destinationBytesPerRow: Int
    ) {
        guard sourceWidth > 0, sourceHeight > 0, destinationWidth > 0, destinationHeight > 0 else {
            return
        }

        for y in 0..<destinationHeight {
            let sourceY = min(sourceHeight - 1, y * sourceHeight / destinationHeight)
            let sourceRow = sourceBaseAddress
                .advanced(by: sourceY * sourceBytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            let destinationRow = destinationBaseAddress
                .advanced(by: y * destinationBytesPerRow)
                .assumingMemoryBound(to: UInt32.self)

            for x in 0..<destinationWidth {
                let sourceX = min(sourceWidth - 1, x * sourceWidth / destinationWidth)
                destinationRow[x] = sourceRow[sourceX]
            }
        }
    }

    private static func makeStreamFormat(for frameSize: OutputFrameSize) -> CMIOExtensionStreamFormat {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: SharedFrameConfiguration.pixelFormat,
            width: Int32(frameSize.width),
            height: Int32(frameSize.height),
            extensions: nil,
            formatDescriptionOut: &description
        )

        return CMIOExtensionStreamFormat(
            formatDescription: description!,
            maxFrameDuration: CMTime(value: 1, timescale: extensionFrameRate),
            minFrameDuration: CMTime(value: 1, timescale: extensionFrameRate),
            validFrameDurations: nil
        )
    }

    private static func formatIndex(for frameSize: OutputFrameSize) -> Int {
        OutputFrameSize.allCases.firstIndex(of: frameSize) ?? 0
    }

    private func drawFallbackFrame(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stripeX = fallbackPhase % max(width, 1)
        fallbackPhase = (fallbackPhase + 6) % max(width, 1)

        let background: UInt32 = 0xFF_18_18_1A
        let stripe: UInt32 = 0xFF_42_A5_F5

        for y in 0..<height {
            let row = baseAddress.advanced(by: y * rowBytes)
            for x in 0..<width {
                let pixel = row.advanced(by: x * MemoryLayout<UInt32>.size)
                let value = abs(x - stripeX) < 4 ? stripe : background
                pixel.storeBytes(of: value, as: UInt32.self)
            }
        }
    }
}

final class EmynVirtualCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice
    private let streamFormats: [CMIOExtensionStreamFormat]
    private var activeFormatIndex = 0

    init(
        localizedName: String,
        streamID: UUID,
        streamFormats: [CMIOExtensionStreamFormat],
        activeFormatIndex: Int,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self.streamFormats = streamFormats
        self.activeFormatIndex = activeFormatIndex
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        streamFormats
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: extensionFrameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            setActiveFormatIndex(activeFormatIndex, notify: false)
            if OutputFrameSize.allCases.indices.contains(activeFormatIndex),
               let deviceSource = device.source as? EmynVirtualCameraDeviceSource {
                deviceSource.setOutputFrameSize(OutputFrameSize.allCases[activeFormatIndex])
            }
        }
    }

    func setActiveFormatIndex(_ activeFormatIndex: Int, notify: Bool) {
        guard streamFormats.indices.contains(activeFormatIndex),
              self.activeFormatIndex != activeFormatIndex else {
            return
        }

        self.activeFormatIndex = activeFormatIndex
        guard notify else { return }

        stream.notifyPropertiesChanged([
            .streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(
                value: NSNumber(value: activeFormatIndex)
            )
        ])
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? EmynVirtualCameraDeviceSource else {
            fatalError("Unexpected device source: \(String(describing: device.source))")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? EmynVirtualCameraDeviceSource else {
            fatalError("Unexpected device source: \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }
}

final class EmynVirtualCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!

    private var deviceSource: EmynVirtualCameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = EmynVirtualCameraDeviceSource(localizedName: SharedFrameConfiguration.virtualCameraName)

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
    }

    func disconnect(from client: CMIOExtensionClient) {
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName, .providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            providerProperties.name = "Emyn"
        }
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Stylemac"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
    }
}
