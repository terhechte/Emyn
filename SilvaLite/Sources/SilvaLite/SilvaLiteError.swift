import Foundation

public enum SilvaLiteError: Error, LocalizedError {
    case appNotFound(String)
    case inputSimulationFailed(String)
    case invalidKeySpec(String)
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let query):
            return "App not found: \(query)"
        case .inputSimulationFailed(let detail):
            return "Input simulation failed: \(detail)"
        case .invalidKeySpec(let spec):
            return "Invalid key specification: \(spec)"
        case .permissionDenied:
            return "Accessibility permission is required to control other apps"
        }
    }
}
