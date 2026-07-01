import CoreMediaIO
import CoreVideo
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
    private var fallbackPhase = 0

    init(localizedName: String) {
        super.init()
        frameReader = try? SharedFrameReader()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: VirtualCameraIDs.device,
            legacyDeviceID: VirtualCameraIDs.legacyDevice,
            source: self
        )

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: SharedFrameConfiguration.pixelFormat,
            width: Int32(SharedFrameConfiguration.width),
            height: Int32(SharedFrameConfiguration.height),
            extensions: nil,
            formatDescriptionOut: &videoDescription
        )

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: SharedFrameConfiguration.width,
            kCVPixelBufferHeightKey: SharedFrameConfiguration.height,
            kCVPixelBufferPixelFormatTypeKey: SharedFrameConfiguration.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &bufferPool)

        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: extensionFrameRate),
            minFrameDuration: CMTime(value: 1, timescale: extensionFrameRate),
            validFrameDurations: nil
        )

        streamSource = EmynVirtualCameraStreamSource(
            localizedName: "Emyn Virtual Camera Video",
            streamID: VirtualCameraIDs.stream,
            streamFormat: videoStreamFormat,
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

    private func sendFrame() {
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

        if frameReader?.copyLatestFrame(to: pixelBuffer) == nil {
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
        streamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
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
    private let streamFormat: CMIOExtensionStreamFormat
    private var activeFormatIndex = 0

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self.streamFormat = streamFormat
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
        [streamFormat]
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
            self.activeFormatIndex = activeFormatIndex
        }
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
