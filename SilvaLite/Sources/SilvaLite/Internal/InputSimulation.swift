import ApplicationServices
import CoreGraphics
import Foundation

enum InputSimulation {

    static func click(at point: CGPoint, button: MouseButton, clickCount: Int, pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw SilvaLiteError.inputSimulationFailed("Failed to create event source")
        }
        let btn = button.cgButton
        let count = max(clickCount, 1)
        for _ in 0..<count {
            try post(.mouseMoved,          source: source, at: point, button: btn, clickState: count, pid: pid)
            try post(button.downEventType, source: source, at: point, button: btn, clickState: count, pid: pid)
            try post(button.upEventType,   source: source, at: point, button: btn, clickState: count, pid: pid)
        }
    }

    static func scroll(at point: CGPoint, direction: ScrollDirection, pages: Double, pid: pid_t) throws {
        let delta = scrollDelta(pages: pages)
        let (w1, w2): (Int32, Int32)
        switch direction {
        case .up:    (w1, w2) = (delta, 0)
        case .down:  (w1, w2) = (-delta, 0)
        case .left:  (w1, w2) = (0, delta)
        case .right: (w1, w2) = (0, -delta)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                  wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0) else {
            throw SilvaLiteError.inputSimulationFailed("Failed to create scroll event")
        }
        event.location = point
        event.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.1)
    }

    static func drag(from start: CGPoint, to end: CGPoint, pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw SilvaLiteError.inputSimulationFailed("Failed to create event source")
        }
        try post(.mouseMoved,    source: source, at: start, button: .left, clickState: 1, pid: pid)
        try post(.leftMouseDown, source: source, at: start, button: .left, clickState: 1, pid: pid)
        for step in 1...10 {
            let t = CGFloat(step) / 10
            let mid = CGPoint(x: start.x + (end.x - start.x) * t,
                              y: start.y + (end.y - start.y) * t)
            try post(.leftMouseDragged, source: source, at: mid, button: .left, clickState: 1, pid: pid)
        }
        try post(.leftMouseUp, source: source, at: end, button: .left, clickState: 1, pid: pid)
    }

    static func typeText(_ text: String, pid: pid_t) throws {
        for var chunk in unicodeChunks(for: text) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw SilvaLiteError.inputSimulationFailed("Failed to create keyboard event")
            }
            chunk.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            }
            down.postToPid(pid)
            up.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    static func pressKey(_ specification: String, pid: pid_t) throws {
        let parsed = try KeyPressParser.parse(specification)
        var flags: CGEventFlags = []

        for mod in parsed.modifiers {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: mod.keyCode, keyDown: true) else {
                throw SilvaLiteError.inputSimulationFailed("Failed to create modifier event")
            }
            flags.insert(mod.flag)
            e.flags = flags
            e.postToPid(pid)
        }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) else {
            throw SilvaLiteError.inputSimulationFailed("Failed to create key event")
        }
        down.flags = flags; down.postToPid(pid)
        up.flags   = flags; up.postToPid(pid)

        for mod in parsed.modifiers.reversed() {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: mod.keyCode, keyDown: false) else {
                throw SilvaLiteError.inputSimulationFailed("Failed to create modifier key-up event")
            }
            e.flags = flags
            e.postToPid(pid)
            flags.remove(mod.flag)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    // MARK: – Private helpers

    private static func post(_ type: CGEventType, source: CGEventSource,
                             at point: CGPoint, button: CGMouseButton,
                             clickState: Int, pid: pid_t) throws {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button) else {
            throw SilvaLiteError.inputSimulationFailed("Failed to create mouse event \(type.rawValue)")
        }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
    }

    private static func scrollDelta(pages: Double) -> Int32 {
        let raw = (12.0 * pages).rounded(.toNearestOrAwayFromZero)
        return Int32(min(Double(Int32.max), max(1, raw)))
    }

    private static func unicodeChunks(for text: String, maxUTF16: Int = 64) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for char in text {
            let units = Array(String(char).utf16)
            if !current.isEmpty, current.count + units.count > maxUTF16 {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
