import XCTest
@testable import VideoCompositionKit

final class LatestFrameRenderGatePerformanceTests: XCTestCase {
    func testKeepsOnlyLatestPendingFrameWhenRenderIsBusy() {
        let gate = LatestFrameRenderGate<Int>()

        XCTAssertEqual(gate.begin(with: 1), 1)
        XCTAssertNil(gate.begin(with: 2))
        XCTAssertNil(gate.begin(with: 3))

        XCTAssertEqual(gate.finish(), 3)
        XCTAssertNil(gate.finish())
        XCTAssertEqual(gate.begin(with: 4), 4)
    }

    func testRenderOverrunThroughputMetric() {
        let inputFrames = 90
        let inputFrameInterval = 1.0 / 30.0
        let renderDuration = 0.040

        let dropIfBusy = Self.simulateDropIfBusy(
            inputFrames: inputFrames,
            inputFrameInterval: inputFrameInterval,
            renderDuration: renderDuration
        )
        let latestPending = Self.simulateLatestPending(
            inputFrames: inputFrames,
            inputFrameInterval: inputFrameInterval,
            renderDuration: renderDuration
        )

        XCTAssertEqual(dropIfBusy.renderedFrames.count, 45)
        XCTAssertEqual(latestPending.renderedFrames.count, 76)
        XCTAssertEqual(latestPending.renderedFrames.last, inputFrames - 1)
        XCTAssertGreaterThan(
            Double(latestPending.renderedFrames.count) / Double(dropIfBusy.renderedFrames.count),
            1.6
        )
    }

    func testLatestPendingGatePerformance() {
        measure(metrics: [XCTClockMetric()]) {
            _ = Self.simulateLatestPending(
                inputFrames: 10_000,
                inputFrameInterval: 1.0 / 30.0,
                renderDuration: 0.040
            )
        }
    }

    private static func simulateDropIfBusy(
        inputFrames: Int,
        inputFrameInterval: Double,
        renderDuration: Double
    ) -> SimulationResult {
        var renderedFrames: [Int] = []
        var renderBusyUntil: Double?

        for frame in 0..<inputFrames {
            let timestamp = Double(frame) * inputFrameInterval
            if let busyUntil = renderBusyUntil, timestamp < busyUntil {
                continue
            }

            renderedFrames.append(frame)
            renderBusyUntil = timestamp + renderDuration
        }

        return SimulationResult(renderedFrames: renderedFrames)
    }

    private static func simulateLatestPending(
        inputFrames: Int,
        inputFrameInterval: Double,
        renderDuration: Double
    ) -> SimulationResult {
        let gate = LatestFrameRenderGate<Int>()
        var renderedFrames: [Int] = []
        var renderBusyUntil: Double?

        func startRender(frame: Int, at timestamp: Double) {
            renderedFrames.append(frame)
            renderBusyUntil = timestamp + renderDuration
        }

        for frame in 0..<inputFrames {
            let timestamp = Double(frame) * inputFrameInterval

            while let busyUntil = renderBusyUntil, busyUntil <= timestamp {
                if let pendingFrame = gate.finish() {
                    startRender(frame: pendingFrame, at: busyUntil)
                } else {
                    renderBusyUntil = nil
                }
            }

            if let acceptedFrame = gate.begin(with: frame) {
                startRender(frame: acceptedFrame, at: timestamp)
            }
        }

        while let busyUntil = renderBusyUntil {
            if let pendingFrame = gate.finish() {
                startRender(frame: pendingFrame, at: busyUntil)
            } else {
                renderBusyUntil = nil
            }
        }

        return SimulationResult(renderedFrames: renderedFrames)
    }
}

private struct SimulationResult {
    var renderedFrames: [Int]
}
