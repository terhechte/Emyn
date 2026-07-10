import XCTest
@testable import VideoCompositionKit

final class NtscEffectFrameSizerTests: XCTestCase {
    func testUsesHalfSizeForOutputFrame() {
        let size = NtscEffectFrameSizer.processingSize(width: 1280, height: 720)

        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 360)
    }

    func testKeepsMinimumOnePixelDimension() {
        let size = NtscEffectFrameSizer.processingSize(width: 1, height: 1)

        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 1)
    }

    func testRoundsOddDimensionsDown() {
        let size = NtscEffectFrameSizer.processingSize(width: 1279, height: 719)

        XCTAssertEqual(size.width, 639)
        XCTAssertEqual(size.height, 359)
    }
}
