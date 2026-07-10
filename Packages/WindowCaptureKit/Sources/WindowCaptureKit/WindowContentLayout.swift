import CoreGraphics

public enum BackgroundMediaFit: String, CaseIterable, Identifiable, Sendable {
    case fill
    case contain
    case scale

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fill: return "Fill"
        case .contain: return "Contain"
        case .scale: return "Scale"
        }
    }
}

public enum BackgroundContentAlignment: String, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case middleCenter
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .middleCenter: return "Middle Center"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }

    public func origin(for contentSize: CGSize, in outputExtent: CGRect) -> CGPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .middleLeft, .bottomLeft:
            x = outputExtent.minX
        case .topCenter, .middleCenter, .bottomCenter:
            x = outputExtent.midX - contentSize.width * 0.5
        case .topRight, .middleRight, .bottomRight:
            x = outputExtent.maxX - contentSize.width
        }

        let y: CGFloat
        switch self {
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = outputExtent.minY
        case .middleLeft, .middleCenter, .middleRight:
            y = outputExtent.midY - contentSize.height * 0.5
        case .topLeft, .topCenter, .topRight:
            y = outputExtent.maxY - contentSize.height
        }

        return CGPoint(x: x, y: y)
    }
}
