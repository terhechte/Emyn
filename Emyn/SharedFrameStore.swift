import CoreMedia
import CoreVideo
import Darwin
import Foundation

enum SharedFrameConfiguration {
    static let appGroupIdentifier = "group.com.stylemac.Emyn"
    static let sharedFileName = "VirtualCameraFrame.dat"
    static let virtualCameraName = "Emyn Virtual Camera"
    static let systemExtensionBundleIdentifier = "com.stylemac.Emyn.VirtualCameraExtension"

    static let width = 1280
    static let height = 720
    static let bytesPerPixel = 4
    static let bytesPerRow = width * bytesPerPixel
    static let frameByteCount = bytesPerRow * height
    static let headerByteCount = 64
    static let fileByteCount = headerByteCount + frameByteCount
    static let pixelFormat = kCVPixelFormatType_32BGRA

    static let magic: UInt32 = 0x454D_594E
    static let version: UInt32 = 1
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

        if createIfNeeded {
            guard ftruncate(descriptor, off_t(SharedFrameConfiguration.fileByteCount)) == 0 else {
                let reason = Self.lastErrnoDescription()
                Darwin.close(descriptor)
                throw SharedFrameStoreError.couldNotResizeFile(reason)
            }
        }

        let mapped = mmap(
            nil,
            SharedFrameConfiguration.fileByteCount,
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
        self.byteCount = SharedFrameConfiguration.fileByteCount
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
        guard CVPixelBufferGetWidth(pixelBuffer) == SharedFrameConfiguration.width,
              CVPixelBufferGetHeight(pixelBuffer) == SharedFrameConfiguration.height,
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
        writeUInt32(UInt32(SharedFrameConfiguration.width), at: Offset.width)
        writeUInt32(UInt32(SharedFrameConfiguration.height), at: Offset.height)
        writeUInt32(UInt32(SharedFrameConfiguration.bytesPerRow), at: Offset.bytesPerRow)
        writeUInt32(SharedFrameConfiguration.pixelFormat, at: Offset.pixelFormat)
        writeUInt64(UInt64(SharedFrameConfiguration.frameByteCount), at: Offset.payloadByteCount)
        writeUInt64(Self.nanoseconds(from: presentationTime), at: Offset.timestampNanoseconds)

        let destinationBaseAddress = mappedFile.pointer.advanced(by: SharedFrameConfiguration.headerByteCount)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let copyBytesPerRow = min(sourceBytesPerRow, SharedFrameConfiguration.bytesPerRow)

        for row in 0..<SharedFrameConfiguration.height {
            memcpy(
                destinationBaseAddress.advanced(by: row * SharedFrameConfiguration.bytesPerRow),
                sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
                copyBytesPerRow
            )
        }

        writeUInt64(nextOddSequence + 1, at: Offset.sequence)
    }

    private func initializeHeader() {
        writeUInt32(SharedFrameConfiguration.magic, at: Offset.magic)
        writeUInt32(SharedFrameConfiguration.version, at: Offset.version)
        writeUInt32(UInt32(SharedFrameConfiguration.width), at: Offset.width)
        writeUInt32(UInt32(SharedFrameConfiguration.height), at: Offset.height)
        writeUInt32(UInt32(SharedFrameConfiguration.bytesPerRow), at: Offset.bytesPerRow)
        writeUInt32(SharedFrameConfiguration.pixelFormat, at: Offset.pixelFormat)
        writeUInt64(UInt64(SharedFrameConfiguration.frameByteCount), at: Offset.payloadByteCount)
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

    init() throws {
        mappedFile = try SharedFrameMappedFile(createIfNeeded: false)
    }

    func copyLatestFrame(to pixelBuffer: CVPixelBuffer) -> SharedFrameSnapshot? {
        guard CVPixelBufferGetWidth(pixelBuffer) == SharedFrameConfiguration.width,
              CVPixelBufferGetHeight(pixelBuffer) == SharedFrameConfiguration.height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == SharedFrameConfiguration.pixelFormat else {
            return nil
        }

        for _ in 0..<3 {
            let sequenceBeforeCopy = readUInt64(at: Offset.sequence)
            guard sequenceBeforeCopy > 0, sequenceBeforeCopy.isMultiple(of: 2), metadataIsValid else {
                return nil
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            guard let destinationBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                return nil
            }

            let sourceBaseAddress = mappedFile.pointer.advanced(by: SharedFrameConfiguration.headerByteCount)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let copyBytesPerRow = min(destinationBytesPerRow, SharedFrameConfiguration.bytesPerRow)

            for row in 0..<SharedFrameConfiguration.height {
                memcpy(
                    destinationBaseAddress.advanced(by: row * destinationBytesPerRow),
                    sourceBaseAddress.advanced(by: row * SharedFrameConfiguration.bytesPerRow),
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

    private var metadataIsValid: Bool {
        readUInt32(at: Offset.magic) == SharedFrameConfiguration.magic
            && readUInt32(at: Offset.version) == SharedFrameConfiguration.version
            && readUInt32(at: Offset.width) == UInt32(SharedFrameConfiguration.width)
            && readUInt32(at: Offset.height) == UInt32(SharedFrameConfiguration.height)
            && readUInt32(at: Offset.bytesPerRow) == UInt32(SharedFrameConfiguration.bytesPerRow)
            && readUInt32(at: Offset.pixelFormat) == SharedFrameConfiguration.pixelFormat
            && readUInt64(at: Offset.payloadByteCount) == UInt64(SharedFrameConfiguration.frameByteCount)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: mappedFile.pointer.load(fromByteOffset: offset, as: UInt32.self))
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: mappedFile.pointer.load(fromByteOffset: offset, as: UInt64.self))
    }
}
