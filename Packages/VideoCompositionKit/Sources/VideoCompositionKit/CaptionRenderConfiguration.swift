import AppKit
import Foundation

public enum CaptionFontStyle: String, CaseIterable, Identifiable, Sendable {
    case system
    case rounded
    case serif
    case monospaced

    public var id: String { rawValue }

    public func nsFont(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        switch self {
        case .system:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .rounded:
            let systemFont = NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = systemFont.fontDescriptor.withDesign(.rounded) ?? systemFont.fontDescriptor
            return NSFont(descriptor: descriptor, size: size) ?? systemFont
        case .serif:
            return NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }
}

public enum CaptionWidth: Double, CaseIterable, Identifiable, Sendable {
    case full = 1
    case eighty = 0.8
    case twoThirds = 0.66
    case half = 0.5

    public var id: Double { rawValue }
}

public enum CaptionAlignment: String, CaseIterable, Identifiable, Sendable {
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
}

public struct CaptionColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var nsColor: NSColor {
        NSColor(
            srgbRed: max(0, min(1, red)),
            green: max(0, min(1, green)),
            blue: max(0, min(1, blue)),
            alpha: max(0, min(1, alpha))
        )
    }

    public static let white = CaptionColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let translucentBlack = CaptionColor(red: 0, green: 0, blue: 0, alpha: 0.72)
}

public struct CaptionRenderConfiguration: Equatable, Sendable {
    public var font: CaptionFontStyle
    public var fontSize: Double
    public var fontColor: CaptionColor
    public var backgroundColor: CaptionColor
    public var width: CaptionWidth
    public var padding: Double
    public var alignment: CaptionAlignment
    public var isAffectedByNTSC: Bool

    public init(
        font: CaptionFontStyle,
        fontSize: Double,
        fontColor: CaptionColor,
        backgroundColor: CaptionColor,
        width: CaptionWidth,
        padding: Double,
        alignment: CaptionAlignment,
        isAffectedByNTSC: Bool
    ) {
        self.font = font
        self.fontSize = fontSize
        self.fontColor = fontColor
        self.backgroundColor = backgroundColor
        self.width = width
        self.padding = padding
        self.alignment = alignment
        self.isAffectedByNTSC = isAffectedByNTSC
    }

    public static let defaultValue = CaptionRenderConfiguration(
        font: .system,
        fontSize: 30,
        fontColor: .white,
        backgroundColor: .translucentBlack,
        width: .eighty,
        padding: 14,
        alignment: .bottomCenter,
        isAffectedByNTSC: false
    )
}
