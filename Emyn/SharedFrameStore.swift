import CoreMedia
import CoreVideo
import Darwin
import Foundation

enum OutputFrameSize: String, CaseIterable, Identifiable {
    case p540 = "960x540"
    case p720 = "1280x720"
    case p1080 = "1920x1080"

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .p540:
            return 960
        case .p720:
            return 1280
        case .p1080:
            return 1920
        }
    }

    var height: Int {
        switch self {
        case .p540:
            return 540
        case .p720:
            return 720
        case .p1080:
            return 1080
        }
    }

    var title: String {
        switch self {
        case .p540:
            return "540p"
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        }
    }

    var dimensionsTitle: String {
        "\(width)x\(height)"
    }

    var bytesPerRow: Int {
        width * SharedFrameConfiguration.bytesPerPixel
    }

    var frameByteCount: Int {
        bytesPerRow * height
    }

    init?(width: Int, height: Int) {
        guard let size = Self.allCases.first(where: { $0.width == width && $0.height == height }) else {
            return nil
        }

        self = size
    }
}

enum SharedFrameConfiguration {
    static let appGroupIdentifier = "group.com.stylemac.Emyn"
    static let sharedFileName = "VirtualCameraFrame.dat"
    static let virtualCameraName = "Emyn Virtual Camera"
    static let systemExtensionBundleIdentifier = "com.stylemac.Emyn.VirtualCameraExtension"
    static let outputFrameSizeDefaultsKey = "OutputFrameSize"
    static let defaultOutputFrameSize: OutputFrameSize = .p720

    static let bytesPerPixel = 4
    static let headerByteCount = 64
    static let pixelFormat = kCVPixelFormatType_32BGRA

    static let magic: UInt32 = 0x454D_594E
    static let version: UInt32 = 1

    static var outputFrameSize: OutputFrameSize {
        get {
            guard let rawValue = sharedDefaults.string(forKey: outputFrameSizeDefaultsKey),
                  let size = OutputFrameSize(rawValue: rawValue) else {
                return defaultOutputFrameSize
            }

            return size
        }
        set {
            sharedDefaults.set(newValue.rawValue, forKey: outputFrameSizeDefaultsKey)
            _ = sharedDefaults.synchronize()
        }
    }

    static var width: Int {
        outputFrameSize.width
    }

    static var height: Int {
        outputFrameSize.height
    }

    static var bytesPerRow: Int {
        outputFrameSize.bytesPerRow
    }

    static var frameByteCount: Int {
        outputFrameSize.frameByteCount
    }

    static var maximumFrameByteCount: Int {
        OutputFrameSize.allCases.map(\.frameByteCount).max() ?? defaultOutputFrameSize.frameByteCount
    }

    static var fileByteCount: Int {
        headerByteCount + maximumFrameByteCount
    }

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

enum SharedFrameStoreError: LocalizedError {
    case missingAppGroupContainer
    case couldNotOpenFile(String)
    case couldNotResizeFile(String)
    case couldNotMapFile(String)

    var errorDescription: String? {
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

struct SharedFrameSnapshot {
    let sequence: UInt64
    let timestampNanoseconds: UInt64
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

final class SharedFrameWriter {
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

    init() throws {
        mappedFile = try SharedFrameMappedFile(createIfNeeded: true)
        initializeHeader()
    }

    func publish(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
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

final class SharedFrameReader {
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

    private struct Metadata {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var pixelFormat: OSType
        var payloadByteCount: UInt64
    }

    init() throws {
        mappedFile = try SharedFrameMappedFile(createIfNeeded: false)
    }

    func copyLatestFrame(to pixelBuffer: CVPixelBuffer) -> SharedFrameSnapshot? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == SharedFrameConfiguration.pixelFormat else {
            return nil
        }

        for _ in 0..<3 {
            let sequenceBeforeCopy = readUInt64(at: Offset.sequence)
            let metadata = readMetadata()
            guard sequenceBeforeCopy > 0,
                  sequenceBeforeCopy.isMultiple(of: 2),
                  metadataIsValid(metadata, for: pixelBuffer) else {
                return nil
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            guard let destinationBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                return nil
            }

            let sourceBaseAddress = mappedFile.pointer.advanced(by: SharedFrameConfiguration.headerByteCount)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let copyBytesPerRow = min(destinationBytesPerRow, metadata.bytesPerRow)

            for row in 0..<metadata.height {
                memcpy(
                    destinationBaseAddress.advanced(by: row * destinationBytesPerRow),
                    sourceBaseAddress.advanced(by: row * metadata.bytesPerRow),
                    copyBytesPerRow
                )
            }

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let sequenceAfterCopy = readUInt64(at: Offset.sequence)
            if sequenceBeforeCopy == sequenceAfterCopy, sequenceAfterCopy.isMultiple(of: 2) {
                return SharedFrameSnapshot(
                    sequence: sequenceAfterCopy,
                    timestampNanoseconds: readUInt64(at: Offset.timestampNanoseconds)
                )
            }
        }

        return nil
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

    private func metadataIsValid(_ metadata: Metadata, for pixelBuffer: CVPixelBuffer) -> Bool {
        guard readUInt32(at: Offset.magic) == SharedFrameConfiguration.magic,
              readUInt32(at: Offset.version) == SharedFrameConfiguration.version,
              OutputFrameSize(width: metadata.width, height: metadata.height) != nil,
              metadata.bytesPerRow == metadata.width * SharedFrameConfiguration.bytesPerPixel,
              metadata.pixelFormat == SharedFrameConfiguration.pixelFormat,
              metadata.payloadByteCount == UInt64(metadata.bytesPerRow * metadata.height),
              metadata.payloadByteCount <= UInt64(SharedFrameConfiguration.maximumFrameByteCount) else {
            return false
        }

        return CVPixelBufferGetWidth(pixelBuffer) == metadata.width
            && CVPixelBufferGetHeight(pixelBuffer) == metadata.height
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: mappedFile.pointer.load(fromByteOffset: offset, as: UInt32.self))
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: mappedFile.pointer.load(fromByteOffset: offset, as: UInt64.self))
    }
}
