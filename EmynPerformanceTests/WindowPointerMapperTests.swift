import CoreGraphics
import XCTest
@testable import WindowCaptureKit

final class WindowPointerMapperTests: XCTestCase {
    func testFillMapsPreviewToOnlyVisibleWindowCrop() throws {
        let mapping = try XCTUnwrap(WindowPointerMapper.mapping(
            for: CGRect(x: 0, y: 0, width: 1_600, height: 1_200),
            fit: .fill,
            alignment: .middleCenter,
            outputSize: CGSize(width: 1_280, height: 720),
            viewBounds: CGRect(x: 0, y: 0, width: 1_280, height: 720)
        ))

        XCTAssertEqual(mapping.viewRect, CGRect(x: 0, y: 0, width: 1_280, height: 720))
        XCTAssertEqual(mapping.targetRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(mapping.targetRect.origin.y, 150, accuracy: 0.001)
        XCTAssertEqual(mapping.targetRect.width, 1_600, accuracy: 0.001)
        XCTAssertEqual(mapping.targetRect.height, 900, accuracy: 0.001)
    }

    func testContainRestrictsControlToLetterboxedContent() throws {
        let mapping = try XCTUnwrap(WindowPointerMapper.mapping(
            for: CGRect(x: 40, y: 50, width: 1_600, height: 1_200),
            fit: .contain,
            alignment: .middleCenter,
            outputSize: CGSize(width: 1_280, height: 720),
            viewBounds: CGRect(x: 0, y: 0, width: 1_280, height: 720)
        ))

        XCTAssertEqual(mapping.viewRect, CGRect(x: 160, y: 0, width: 960, height: 720))
        XCTAssertEqual(mapping.targetRect, CGRect(x: 40, y: 50, width: 1_600, height: 1_200))
    }

    func testFillHonorsTopAlignmentWhenComputingTargetCrop() throws {
        let mapping = try XCTUnwrap(WindowPointerMapper.mapping(
            for: CGRect(x: 0, y: 0, width: 1_600, height: 1_200),
            fit: .fill,
            alignment: .topCenter,
            outputSize: CGSize(width: 1_280, height: 720),
            viewBounds: CGRect(x: 0, y: 0, width: 1_280, height: 720)
        ))

        XCTAssertEqual(mapping.targetRect.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(mapping.targetRect.height, 900, accuracy: 0.001)
    }
}
