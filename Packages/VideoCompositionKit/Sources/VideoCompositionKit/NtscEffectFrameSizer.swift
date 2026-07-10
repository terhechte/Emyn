import Foundation

public enum NtscEffectFrameSizer {
    public static func processingSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (
            width: max(1, width / 2),
            height: max(1, height / 2)
        )
    }
}
