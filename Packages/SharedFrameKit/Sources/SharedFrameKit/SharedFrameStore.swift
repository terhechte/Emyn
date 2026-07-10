import CoreMedia
import CoreVideo
import Darwin
import Foundation

public enum OutputFrameSize: String, CaseIterable, Identifiable {
    case p540 = "960x540"
    case p720 = "1280x720"
    case p1080 = "1920x1080"

    public var id: String { rawValue }

    public var width: Int {
        switch self {
        case .p540:
            return 960
        case .p720:
            return 1280
        case .p1080:
            return 1920
        }
    }

    public var height: Int {
        switch self {
        case .p540:
            return 540
        case .p720:
            return 720
        case .p1080:
            return 1080
        }
    }

    public var title: String {
        switch self {
        case .p540:
            return "540p"
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        }
    }

    public var dimensionsTitle: String {
        "\(width)x\(height)"
    }

    public var bytesPerRow: Int {
        width * SharedFrameConfiguration.bytesPerPixel
    }

    public var frameByteCount: Int {
        bytesPerRow * height
    }

    public init?(width: Int, height: Int) {
        guard let size = Self.allCases.first(where: { $0.width == width && $0.height == height }) else {
            return nil
        }

        self = size
    }
}

public enum SharedFrameConfiguration {
    public static let appGroupIdentifier = "group.com.stylemac.Emyn"
    public static let sharedFileName = "VirtualCameraFrame.dat"
    public static let virtualCameraName = "Emyn Virtual Camera"
    public static let systemExtensionBundleIdentifier = "com.stylemac.Emyn.VirtualCameraExtension"
    public static let outputFrameSizeDefaultsKey = "OutputFrameSize"
    public static let defaultOutputFrameSize: OutputFrameSize = .p720

    public static let bytesPerPixel = 4
    public static let headerByteCount = 64
    public static let pixelFormat = kCVPixelFormatType_32BGRA

    public static let magic: UInt32 = 0x454D_594E
    public static let version: UInt32 = 1

    public static var outputFrameSize: OutputFrameSize {
        get {
            outputFrameSize(from: sharedDefaults)
        }
        set {
            let defaults = sharedDefaults
            defaults.set(newValue.rawValue, forKey: outputFrameSizeDefaultsKey)
            _ = defaults.synchronize()
        }
    }

    public static func synchronizedOutputFrameSize() -> OutputFrameSize {
        let defaults = sharedDefaults
        _ = defaults.synchronize()
        return outputFrameSize(from: defaults)
    }

    public static var width: Int {
        outputFrameSize.width
    }

    public static var height: Int {
        outputFrameSize.height
    }

    public static var bytesPerRow: Int {
        outputFrameSize.bytesPerRow
    }

    public static var frameByteCount: Int {
        outputFrameSize.frameByteCount
    }

    public static var maximumFrameByteCount: Int {
        OutputFrameSize.allCases.map(\.frameByteCount).max() ?? defaultOutputFrameSize.frameByteCount
    }

    public static var fileByteCount: Int {
        headerByteCount + maximumFrameByteCount
    }

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func outputFrameSize(from defaults: UserDefaults) -> OutputFrameSize {
        guard let rawValue = defaults.string(forKey: outputFrameSizeDefaultsKey),
              let size = OutputFrameSize(rawValue: rawValue) else {
            return defaultOutputFrameSize
        }

        return size
    }
}

public enum SharedFrameStoreError: LocalizedError {
    case missingAppGroupContainer
    case couldNotOpenFile(String)
    case couldNotResizeFile(String)
    case couldNotMapFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer:
            return "The shared app group container is unavailable."
        case .couldNotOpenFile(let reason):
            return "Could not open the shared frame file: \(reason)"
        case .couldNotResizeFile(let reason):
            return "Could not resize the shared frame file: \(reason)"
        case .couldNotMapFile(let reason):
            return "Could not map the shared frame file: \(reason)"
        }
    }
}

public struct SharedFrameSnapshot {
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
}

final class SharedFrameMappedFile {
    let pointer: UnsafeMutableRawPointer

    private let fileDescriptor: Int32
    private let byteCount: Int

    init(createIfNeeded: Bool) throws {
        let directory = try Self.containerDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(SharedFrameConfiguration.sharedFileName)
        let flags = createIfNeeded ? (O_RDWR | O_CREAT) : O_RDWR
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, flags, S_IRUSR | S_IWUSR)
        }

        guard descriptor >= 0 else {
            throw SharedFrameStoreError.couldNotOpenFile(Self.lastErrnoDescription())
        }

        let requiredByteCount = SharedFrameConfiguration.fileByteCount
        if createIfNeeded || Self.fileSize(of: descriptor) < requiredByteCount {
            guard ftruncate(descriptor, off_t(requiredByteCount)) == 0 else {
                let reason = Self.lastErrnoDescription()
                Darwin.close(descriptor)
                throw SharedFrameStoreError.couldNotResizeFile(reason)
            }
        }

        let mapped = mmap(
            nil,
            requiredByteCount,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0
        )

        guard let mapped, mapped != MAP_FAILED else {
            let reason = Self.lastErrnoDescription()
            Darwin.close(descriptor)
            throw SharedFrameStoreError.couldNotMapFile(reason)
        }

        self.fileDescriptor = descriptor
        self.pointer = mapped
        self.byteCount = requiredByteCount
    }

    deinit {
        munmap(pointer, byteCount)
        Darwin.close(fileDescriptor)
    }

    private static func containerDirectory() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedFrameConfiguration.appGroupIdentifier
        ) else {
            throw SharedFrameStoreError.missingAppGroupContainer
        }

        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Emyn", isDirectory: true)
    }

    private static func lastErrnoDescription() -> String {
        String(cString: strerror(errno))
    }

    private static func fileSize(of descriptor: Int32) -> Int {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return 0
        }

        return max(0, Int(info.st_size))
    }
}

public final class SharedFrameWriter {
    private enum Offset {
        static let magic = 0
        static let version = 4
        static let width = 8
        static let height = 12
        static let bytesPerRow = 16
        static let pixelFormat = 20
        static let sequence = 24
        static let timestampNanoseconds = 32
        static let payloadByteCount = 40
    }

    private let mappedFile: SharedFrameMappedFile

    public init() throws {
        mappedFile = try SharedFrameMappedFile(createIfNeeded: true)
        initializeHeader()
    }

    public func publish(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = width * SharedFrameConfiguration.bytesPerPixel
        let frameByteCount = bytesPerRow * height

        guard OutputFrameSize(width: width, height: height) != nil,
              frameByteCount <= SharedFrameConfiguration.maximumFrameByteCount,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == SharedFrameConfiguration.pixelFormat else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let previousSequence = readUInt64(at: Offset.sequence)
        let nextOddSequence = (previousSequence + 1) | 1
        writeUInt64(nextOddSequence, at: Offset.sequence)

        writeUInt32(SharedFrameConfiguration.magic, at: Offset.magic)
        writeUInt32(SharedFrameConfiguration.version, at: Offset.version)
        writeUInt32(UInt32(width), at: Offset.width)
        writeUInt32(UInt32(height), at: Offset.height)
        writeUInt32(UInt32(bytesPerRow), at: Offset.bytesPerRow)
        writeUInt32(SharedFrameConfiguration.pixelFormat, at: Offset.pixelFormat)
        writeUInt64(UInt64(frameByteCount), at: Offset.payloadByteCount)
        writeUInt64(Self.nanoseconds(from: presentationTime), at: Offset.timestampNanoseconds)

        let destinationBaseAddress = mappedFile.pointer.advanced(by: SharedFrameConfiguration.headerByteCount)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let copyBytesPerRow = min(sourceBytesPerRow, bytesPerRow)

        for row in 0..<height {
            memcpy(
                destinationBaseAddress.advanced(by: row * bytesPerRow),
                sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
                copyBytesPerRow
            )
        }

        writeUInt64(nextOddSequence + 1, at: Offset.sequence)
    }

    private func initializeHeader() {
        let frameSize = SharedFrameConfiguration.outputFrameSize
        writeUInt32(SharedFrameConfiguration.magic, at: Offset.magic)
        writeUInt32(SharedFrameConfiguration.version, at: Offset.version)
        writeUInt32(UInt32(frameSize.width), at: Offset.width)
        writeUInt32(UInt32(frameSize.height), at: Offset.height)
        writeUInt32(UInt32(frameSize.bytesPerRow), at: Offset.bytesPerRow)
        writeUInt32(SharedFrameConfiguration.pixelFormat, at: Offset.pixelFormat)
        writeUInt64(UInt64(frameSize.frameByteCount), at: Offset.payloadByteCount)
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: mappedFile.pointer.load(fromByteOffset: offset, as: UInt64.self))
    }

    private func writeUInt32(_ value: UInt32, at offset: Int) {
        mappedFile.pointer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }

    private func writeUInt64(_ value: UInt64, at offset: Int) {
        mappedFile.pointer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
    }

    private static func nanoseconds(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.seconds.isNaN, time.seconds >= 0 else {
            return DispatchTime.now().uptimeNanoseconds
        }

        return UInt64(time.seconds * Double(NSEC_PER_SEC))
    }
}

public final class SharedFrameReader {
    private enum Offset {
        static let magic = 0
        static let version = 4
        static let width = 8
        static let height = 12
        static let bytesPerRow = 16
        static let pixelFormat = 20
        static let sequence = 24
        static let timestampNanoseconds = 32
        static let payloadByteCount = 40
    }

    private let mappedFile: SharedFrameMappedFile
    private static let copyRetryCount = 6
    private static let retryDelayMicroseconds: useconds_t = 500

    private struct Metadata {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var pixelFormat: OSType
        var payloadByteCount: UInt64
    }

    public init() throws {
        mappedFile = try SharedFrameMappedFile(createIfNeeded: false)
    }

    public func copyLatestFrame(to pixelBuffer: CVPixelBuffer) -> SharedFrameSnapshot? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == SharedFrameConfiguration.pixelFormat else {
            return nil
        }

        for attempt in 0..<Self.copyRetryCount {
            let sequenceBeforeCopy = readUInt64(at: Offset.sequence)
            guard sequenceBeforeCopy > 0, sequenceBeforeCopy.isMultiple(of: 2) else {
                waitBeforeRetry(attempt)
                continue
            }

            let metadata = readMetadata()
            guard metadataIsReadable(metadata) else {
                waitBeforeRetry(attempt)
                continue
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            guard let destinationBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                return nil
            }

            let sourceBaseAddress = mappedFile.pointer.advanced(by: SharedFrameConfiguration.headerByteCount)
            let destinationWidth = CVPixelBufferGetWidth(pixelBuffer)
            let destinationHeight = CVPixelBufferGetHeight(pixelBuffer)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            copyFrame(
                metadata,
                from: sourceBaseAddress,
                to: destinationBaseAddress,
                destinationWidth: destinationWidth,
                destinationHeight: destinationHeight,
                destinationBytesPerRow: destinationBytesPerRow
            )

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let sequenceAfterCopy = readUInt64(at: Offset.sequence)
            if sequenceBeforeCopy == sequenceAfterCopy, sequenceAfterCopy.isMultiple(of: 2) {
                return SharedFrameSnapshot(
                    sequence: sequenceAfterCopy,
                    timestampNanoseconds: readUInt64(at: Offset.timestampNanoseconds)
                )
            }

            waitBeforeRetry(attempt)
        }

        return nil
    }

    private func copyFrame(
        _ metadata: Metadata,
        from sourceBaseAddress: UnsafeMutableRawPointer,
        to destinationBaseAddress: UnsafeMutableRawPointer,
        destinationWidth: Int,
        destinationHeight: Int,
        destinationBytesPerRow: Int
    ) {
        if metadata.width == destinationWidth, metadata.height == destinationHeight {
            let copyBytesPerRow = min(destinationBytesPerRow, metadata.bytesPerRow)

            for row in 0..<metadata.height {
                memcpy(
                    destinationBaseAddress.advanced(by: row * destinationBytesPerRow),
                    sourceBaseAddress.advanced(by: row * metadata.bytesPerRow),
                    copyBytesPerRow
                )
            }

            return
        }

        scaleFrame(
            metadata,
            from: sourceBaseAddress,
            to: destinationBaseAddress,
            destinationWidth: destinationWidth,
            destinationHeight: destinationHeight,
            destinationBytesPerRow: destinationBytesPerRow
        )
    }

    private func scaleFrame(
        _ metadata: Metadata,
        from sourceBaseAddress: UnsafeMutableRawPointer,
        to destinationBaseAddress: UnsafeMutableRawPointer,
        destinationWidth: Int,
        destinationHeight: Int,
        destinationBytesPerRow: Int
    ) {
        guard metadata.width > 0, metadata.height > 0, destinationWidth > 0, destinationHeight > 0 else {
            return
        }

        for y in 0..<destinationHeight {
            let sourceY = min(metadata.height - 1, y * metadata.height / destinationHeight)
            let sourceRow = sourceBaseAddress
                .advanced(by: sourceY * metadata.bytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            let destinationRow = destinationBaseAddress
                .advanced(by: y * destinationBytesPerRow)
                .assumingMemoryBound(to: UInt32.self)

            for x in 0..<destinationWidth {
                let sourceX = min(metadata.width - 1, x * metadata.width / destinationWidth)
                destinationRow[x] = sourceRow[sourceX]
            }
        }
    }

    private func waitBeforeRetry(_ attempt: Int) {
        guard attempt + 1 < Self.copyRetryCount else { return }
        usleep(Self.retryDelayMicroseconds)
    }

    private func readMetadata() -> Metadata {
        Metadata(
            width: Int(readUInt32(at: Offset.width)),
            height: Int(readUInt32(at: Offset.height)),
            bytesPerRow: Int(readUInt32(at: Offset.bytesPerRow)),
            pixelFormat: readUInt32(at: Offset.pixelFormat),
            payloadByteCount: readUInt64(at: Offset.payloadByteCount)
        )
    }

    private func metadataIsReadable(_ metadata: Metadata) -> Bool {
        guard readUInt32(at: Offset.magic) == SharedFrameConfiguration.magic,
              readUInt32(at: Offset.version) == SharedFrameConfiguration.version,
              OutputFrameSize(width: metadata.width, height: metadata.height) != nil,
              metadata.bytesPerRow == metadata.width * SharedFrameConfiguration.bytesPerPixel,
              metadata.pixelFormat == SharedFrameConfiguration.pixelFormat,
              metadata.payloadByteCount == UInt64(metadata.bytesPerRow * metadata.height),
              metadata.payloadByteCount <= UInt64(SharedFrameConfiguration.maximumFrameByteCount) else {
            return false
        }

        return true
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: mappedFile.pointer.load(fromByteOffset: offset, as: UInt32.self))
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: mappedFile.pointer.load(fromByteOffset: offset, as: UInt64.self))
    }
}
