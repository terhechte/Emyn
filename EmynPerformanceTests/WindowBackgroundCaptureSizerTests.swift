import XCTest
@testable import EmynPerformanceCore

final class WindowBackgroundCaptureSizerTests: XCTestCase {
    func testCapsSixteenByNineRetinaWindowAtOutputDimensions() {
        let size = WindowBackgroundCaptureSizer.captureSize(
            rawWidth: 5120,
            rawHeight: 2880,
            maxWidth: 1280,
            maxHeight: 720
        )

        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    func testPreservesAspectRatioInsideOutputBounds() {
        let size = WindowBackgroundCaptureSizer.captureSize(
            rawWidth: 2000,
            rawHeight: 2000,
            maxWidth: 1280,
            maxHeight: 720
        )

        XCTAssertEqual(size.width, 720)
        XCTAssertEqual(size.height, 720)
    }

    func testDoesNotUpscaleSmallWindows() {
        let size = WindowBackgroundCaptureSizer.captureSize(
            rawWidth: 640,
            rawHeight: 360,
            maxWidth: 1280,
            maxHeight: 720
        )

        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 360)
    }
}
