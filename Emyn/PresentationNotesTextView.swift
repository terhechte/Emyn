import AppKit
import SwiftUI

struct PresentationNotesTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.applyHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.applyHighlighting(to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PresentationNotesTextView
        private var isApplyingHighlighting = false

        init(_ parent: PresentationNotesTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            parent.text = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard !isApplyingHighlighting else { return }

            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            PresentationMarkdownHighlighter.apply(
                to: textView,
                fontSize: CGFloat(parent.fontSize)
            )
        }
    }
}

private enum PresentationMarkdownHighlighter {
    static func apply(to textView: NSTextView, fontSize: CGFloat) {
        guard let textStorage = textView.textStorage else { return }

        let string = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        let baseFont = NSFont.systemFont(ofSize: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 5

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]

        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        defer {
            textStorage.endEditing()
            undoManager?.enableUndoRegistration()
            textView.typingAttributes = baseAttributes
        }

        if fullRange.length > 0 {
            textStorage.setAttributes(baseAttributes, range: fullRange)
            highlightHeadings(in: textStorage, string: string, fontSize: fontSize)
            highlightBlockquotes(in: textStorage, string: string, fontSize: fontSize)
            highlightListMarkers(in: textStorage, string: string)
            highlightStrong(in: textStorage, string: string)
            highlightEmphasis(in: textStorage, string: string)
            highlightInlineCode(in: textStorage, string: string, fontSize: fontSize)
        }
    }

    private static func highlightHeadings(in textStorage: NSTextStorage, string: NSString, fontSize: CGFloat) {
        enumerateMatches(pattern: #"^(#{1,6})\s+(.+)$"#, options: [.anchorsMatchLines], in: string) { match in
            let markerRange = match.range(at: 1)
            let level = max(1, markerRange.length)
            let headingFontSize = fontSize + max(2, CGFloat(7 - level))
            let headingFont = NSFont.boldSystemFont(ofSize: headingFontSize)

            textStorage.addAttributes(
                [
                    .font: headingFont,
                    .foregroundColor: NSColor.controlAccentColor
                ],
                range: match.range
            )
        }
    }

    private static func highlightBlockquotes(in textStorage: NSTextStorage, string: NSString, fontSize: CGFloat) {
        enumerateMatches(pattern: #"^>.*$"#, options: [.anchorsMatchLines], in: string) { match in
            textStorage.addAttributes(
                [
                    .font: NSFontManager.shared.convert(
                        NSFont.systemFont(ofSize: fontSize),
                        toHaveTrait: .italicFontMask
                    ),
                    .foregroundColor: NSColor.secondaryLabelColor
                ],
                range: match.range
            )
        }
    }

    private static func highlightListMarkers(in textStorage: NSTextStorage, string: NSString) {
        enumerateMatches(pattern: #"^\s*([-*+]|\d+\.)\s+"#, options: [.anchorsMatchLines], in: string) { match in
            textStorage.addAttributes(
                [
                    .font: NSFont.boldSystemFont(ofSize: currentFontSize(in: textStorage, at: match.range.location)),
                    .foregroundColor: NSColor.controlAccentColor
                ],
                range: match.range
            )
        }
    }

    private static func highlightInlineCode(in textStorage: NSTextStorage, string: NSString, fontSize: CGFloat) {
        enumerateMatches(pattern: #"`[^`\n]+`"#, in: string) { match in
            textStorage.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: NSColor.systemPurple,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14)
                ],
                range: match.range
            )
        }
    }

    private static func highlightStrong(in textStorage: NSTextStorage, string: NSString) {
        enumerateMatches(pattern: #"\*\*[^*\n]+\*\*"#, in: string) { match in
            addFontTrait(.boldFontMask, to: textStorage, range: match.range)
        }
    }

    private static func highlightEmphasis(in textStorage: NSTextStorage, string: NSString) {
        enumerateMatches(pattern: #"(?<!\*)\*[^*\n]+\*(?!\*)"#, in: string) { match in
            addFontTrait(.italicFontMask, to: textStorage, range: match.range)
        }
    }

    private static func addFontTrait(
        _ trait: NSFontTraitMask,
        to textStorage: NSTextStorage,
        range: NSRange
    ) {
        guard range.length > 0 else { return }

        let existingFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let convertedFont = NSFontManager.shared.convert(existingFont, toHaveTrait: trait)
        textStorage.addAttribute(.font, value: convertedFont, range: range)
    }

    private static func currentFontSize(in textStorage: NSTextStorage, at location: Int) -> CGFloat {
        guard textStorage.length > 0 else { return NSFont.systemFontSize }

        let clampedLocation = min(max(0, location), textStorage.length - 1)
        let existingFont = textStorage.attribute(.font, at: clampedLocation, effectiveRange: nil) as? NSFont
        return existingFont?.pointSize ?? NSFont.systemFontSize
    }

    private static func enumerateMatches(
        pattern: String,
        options: NSRegularExpression.Options = [],
        in string: NSString,
        body: (NSTextCheckingResult) -> Void
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }

        let fullRange = NSRange(location: 0, length: string.length)
        expression.enumerateMatches(in: string as String, options: [], range: fullRange) { result, _, _ in
            guard let result else { return }
            body(result)
        }
    }
}
