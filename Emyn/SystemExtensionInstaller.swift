import Combine
import Foundation
import SystemExtensions
import SharedFrameKit

enum SystemExtensionInstallationState: Equatable {
    case notInstalled
    case installing
    case awaitingApproval
    case installed
    case requiresReboot
    case requestCompleted
    case removing
    case failed(String)
}

private enum SystemExtensionRequestKind {
    case activation
    case deactivation
}

final class SystemExtensionInstaller: NSObject, ObservableObject {
    @Published private(set) var statusText = "Virtual camera not installed"
    @Published private(set) var needsUserApproval = false
    @Published private(set) var installationState: SystemExtensionInstallationState = .notInstalled

    private let requestQueue = DispatchQueue(label: "com.stylemac.Emyn.system-extension")
    private let requestStateLock = NSLock()
    private var requestKinds: [ObjectIdentifier: SystemExtensionRequestKind] = [:]
    private var isActivationRequestInFlight = false
    private var isDeactivationRequestInFlight = false
    private var shouldActivateAfterDeactivation = false

    override init() {
        super.init()

        if StartupPermissionDefaults.wasVirtualCameraInstalled {
            statusText = "Virtual camera installed"
            installationState = .installed
        }
    }

    func activate() {
        guard !isActivationRequestInFlight else { return }
        isActivationRequestInFlight = true
        StartupPermissionDefaults.setVirtualCameraInstallRequested(true)
        needsUserApproval = false
        statusText = "Installing virtual camera"
        installationState = .installing

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: SharedFrameConfiguration.systemExtensionBundleIdentifier,
            queue: requestQueue
        )
        request.delegate = self
        register(request, kind: .activation)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // macOS only replaces an installed system extension when the bundle version
    // changes, so a same-version rebuild needs an explicit remove + install cycle.
    func reinstall() {
        guard !isActivationRequestInFlight, !isDeactivationRequestInFlight else { return }
        shouldActivateAfterDeactivation = true
        deactivate()
    }

    func deactivate() {
        guard !isDeactivationRequestInFlight else { return }
        isDeactivationRequestInFlight = true
        needsUserApproval = false
        statusText = "Removing virtual camera"
        installationState = .removing
        StartupPermissionDefaults.setVirtualCameraInstalled(false)

        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: SharedFrameConfiguration.systemExtensionBundleIdentifier,
            queue: requestQueue
        )
        request.delegate = self
        register(request, kind: .deactivation)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func noteVirtualCameraAvailable() {
        guard installationState != .installed else { return }

        StartupPermissionDefaults.setVirtualCameraInstallRequested(true)
        StartupPermissionDefaults.setVirtualCameraInstalled(true)
        needsUserApproval = false
        statusText = "Virtual camera installed"
        installationState = .installed
    }

    private func update(
        status: String,
        needsApproval: Bool = false,
        state: SystemExtensionInstallationState? = nil
    ) {
        DispatchQueue.main.async {
            self.statusText = status
            self.needsUserApproval = needsApproval
            if let state {
                self.installationState = state
            }
        }
    }

    private func markActivationFinished() {
        DispatchQueue.main.async {
            self.isActivationRequestInFlight = false
        }
    }

    private func markDeactivationFinished() {
        DispatchQueue.main.async {
            self.isDeactivationRequestInFlight = false
        }
    }

    private func continueReinstallIfNeeded() {
        DispatchQueue.main.async {
            guard self.shouldActivateAfterDeactivation else { return }
            self.shouldActivateAfterDeactivation = false
            self.activate()
        }
    }

    private func register(_ request: OSSystemExtensionRequest, kind: SystemExtensionRequestKind) {
        requestStateLock.lock()
        requestKinds[ObjectIdentifier(request)] = kind
        requestStateLock.unlock()
    }

    private func kind(for request: OSSystemExtensionRequest) -> SystemExtensionRequestKind {
        requestStateLock.lock()
        defer { requestStateLock.unlock() }
        return requestKinds[ObjectIdentifier(request)] ?? .activation
    }

    private func consumeKind(for request: OSSystemExtensionRequest) -> SystemExtensionRequestKind {
        requestStateLock.lock()
        defer { requestStateLock.unlock() }
        return requestKinds.removeValue(forKey: ObjectIdentifier(request)) ?? .activation
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
        guard kind(for: request) == .activation else { return }
        markActivationFinished()
        update(
            status: "Approve the virtual camera in System Settings",
            needsApproval: true,
            state: .awaitingApproval
        )
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let kind = consumeKind(for: request)

        switch result {
        case .completed:
            switch kind {
            case .activation:
                markActivationFinished()
                StartupPermissionDefaults.setVirtualCameraInstalled(true)
                update(status: "Virtual camera installed", state: .installed)
            case .deactivation:
                markDeactivationFinished()
                StartupPermissionDefaults.setVirtualCameraInstallRequested(false)
                StartupPermissionDefaults.setVirtualCameraInstalled(false)
                update(status: "Virtual camera removed", state: .notInstalled)
                continueReinstallIfNeeded()
            }
        case .willCompleteAfterReboot:
            switch kind {
            case .activation:
                markActivationFinished()
                StartupPermissionDefaults.setVirtualCameraInstalled(true)
                update(status: "Virtual camera will finish after restart", state: .requiresReboot)
            case .deactivation:
                markDeactivationFinished()
                StartupPermissionDefaults.setVirtualCameraInstallRequested(false)
                StartupPermissionDefaults.setVirtualCameraInstalled(false)
                update(status: "Virtual camera removal will finish after restart", state: .requiresReboot)
                continueReinstallIfNeeded()
            }
        @unknown default:
            markActivationFinished()
            markDeactivationFinished()
            update(status: "Virtual camera request completed", state: .requestCompleted)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let kind = consumeKind(for: request)
        switch kind {
        case .activation:
            markActivationFinished()
        case .deactivation:
            markDeactivationFinished()
        }
        update(status: error.localizedDescription, state: .failed(error.localizedDescription))
        if kind == .deactivation {
            // Removing may fail when no extension is installed; a pending
            // reinstall should still attempt the fresh activation.
            continueReinstallIfNeeded()
        }
    }
}
