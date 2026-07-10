import TranscriptionKit
import VideoCompositionKit

extension CaptionRenderConfiguration {
    init(_ speechConfiguration: SpeechToTextCaptionRenderConfiguration) {
        self.init(
            font: CaptionFontStyle(rawValue: speechConfiguration.font.rawValue) ?? .system,
            fontSize: speechConfiguration.fontSize,
            fontColor: CaptionColor(
                red: speechConfiguration.fontColor.red,
                green: speechConfiguration.fontColor.green,
                blue: speechConfiguration.fontColor.blue,
                alpha: speechConfiguration.fontColor.alpha
            ),
            backgroundColor: CaptionColor(
                red: speechConfiguration.backgroundColor.red,
                green: speechConfiguration.backgroundColor.green,
                blue: speechConfiguration.backgroundColor.blue,
                alpha: speechConfiguration.backgroundColor.alpha
            ),
            width: CaptionWidth(rawValue: speechConfiguration.width.rawValue) ?? .eighty,
            padding: speechConfiguration.padding,
            alignment: CaptionAlignment(rawValue: speechConfiguration.alignment.rawValue) ?? .bottomCenter,
            isAffectedByNTSC: speechConfiguration.isAffectedByNTSC
        )
    }
}
