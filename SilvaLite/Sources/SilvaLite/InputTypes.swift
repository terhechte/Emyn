import CoreGraphics

/// Which mouse button to use for a click.
public enum MouseButton {
    case left, right, middle

    var cgButton: CGMouseButton {
        switch self {
        case .left:   .left
        case .right:  .right
        case .middle: .center
        }
    }

    var downEventType: CGEventType {
        switch self {
        case .left:   .leftMouseDown
        case .right:  .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    var upEventType: CGEventType {
        switch self {
        case .left:   .leftMouseUp
        case .right:  .rightMouseUp
        case .middle: .otherMouseUp
        }
    }
}

/// Direction for a scroll gesture.
public enum ScrollDirection: String {
    case up, down, left, right
}
