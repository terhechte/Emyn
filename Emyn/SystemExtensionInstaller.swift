import Combine
import Foundation
import SystemExtensions

final class SystemExtensionInstaller: NSObject, ObservableObject {
    @Published private(set) var statusText = "Virtual camera not installed"
    @Published private(set) var needsUserApproval = false

    private let requestQueue = DispatchQueue(label: "com.stylemac.Emyn.system-extension")

    func activate() {
        needsUserApproval = false
        statusText = "Installing virtual camera"

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: SharedFrameConfiguration.systemExtensionBundleIdentifier,
            queue: requestQueue
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        needsUserApproval = false
        statusText = "Removing virtual camera"

        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: SharedFrameConfiguration.systemExtensionBundleIdentifier,
            queue: requestQueue
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func update(status: String, needsApproval: Bool = false) {
        DispatchQueue.main.async {
            self.statusText = status
            self.needsUserApproval = needsApproval
        }
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        update(status: "Approve the virtual camera in System Settings", needsApproval: true)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            update(status: "Virtual camera installed")
        case .willCompleteAfterReboot:
            update(status: "Virtual camera will finish after restart")
        @unknown default:
            update(status: "Virtual camera request completed")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        update(status: error.localizedDescription)
    }
}
