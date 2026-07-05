import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

enum StartupPermissionDefaults {
    private enum Key {
        static let cameraGranted = "startupPermissions.cameraGranted.v1"
        static let microphoneGranted = "startupPermissions.microphoneGranted.v1"
        static let virtualCameraInstallRequested = "startupPermissions.virtualCameraInstallRequested.v1"
        static let virtualCameraInstalled = "startupPermissions.virtualCameraInstalled.v1"
    }

    static var wasVirtualCameraInstallRequested: Bool {
        UserDefaults.standard.bool(forKey: Key.virtualCameraInstallRequested)
    }

    static var wasVirtualCameraInstalled: Bool {
        UserDefaults.standard.bool(forKey: Key.virtualCameraInstalled)
    }

    static func setCameraGranted(_ isGranted: Bool) {
        UserDefaults.standard.set(isGranted, forKey: Key.cameraGranted)
    }

    static func setMicrophoneGranted(_ isGranted: Bool) {
        UserDefaults.standard.set(isGranted, forKey: Key.microphoneGranted)
    }

    static func setVirtualCameraInstallRequested(_ isRequested: Bool) {
        UserDefaults.standard.set(isRequested, forKey: Key.virtualCameraInstallRequested)
    }

    static func setVirtualCameraInstalled(_ isInstalled: Bool) {
        UserDefaults.standard.set(isInstalled, forKey: Key.virtualCameraInstalled)
    }
}

enum StartupPermissionStep: CaseIterable {
    case camera
    case microphone
    case virtualCamera

    var title: String {
        switch self {
        case .camera:
            return "Camera Access"
        case .microphone:
            return "Microphone Access"
        case .virtualCamera:
            return "Virtual Camera"
        }
    }

    var systemImage: String {
        switch self {
        case .camera:
            return "camera.fill"
        case .microphone:
            return "mic.fill"
        case .virtualCamera:
            return "video.badge.plus"
        }
    }

    var explanation: String {
        switch self {
        case .camera:
            return "Emyn needs camera access to read your selected physical camera and render the processed video feed."
        case .microphone:
            return "Emyn needs microphone access for local speech-to-text captions and live microphone selection."
        case .virtualCamera:
            return "Emyn needs to install its virtual camera so the processed feed appears in video conferencing apps."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .camera:
            return "Grant Camera Access"
        case .microphone:
            return "Grant Microphone Access"
        case .virtualCamera:
            return "Install Virtual Camera"
        }
    }

    var systemSettingsURL: URL? {
        switch self {
        case .camera:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .virtualCamera:
            return nil
        }
    }
}

final class StartupPermissionCoordinator: ObservableObject {
    @Published private(set) var currentStep: StartupPermissionStep?
    @Published private(set) var isRequesting = false
    @Published private(set) var statusText = ""

    private var onReady: (() -> Void)?
    private var didSignalReady = false
    private var didAutomaticallyRetryVirtualCameraInstall = false

    var isWizardPresented: Bool {
        currentStep != nil
    }

    var progressTitle: String {
        guard let currentStep else { return "" }
        let stepNumber = StartupPermissionStep.allCases.firstIndex(of: currentStep).map { $0 + 1 } ?? 1
        return "Step \(stepNumber) of \(StartupPermissionStep.allCases.count)"
    }

    var primaryActionTitle: String {
        guard let currentStep else { return "" }

        switch currentStep {
        case .camera:
            return cameraAuthorizationStatus == .denied || cameraAuthorizationStatus == .restricted
                ? "Open Camera Settings"
                : currentStep.primaryActionTitle
        case .microphone:
            return microphoneAuthorizationStatus == .denied || microphoneAuthorizationStatus == .restricted
                ? "Open Microphone Settings"
                : currentStep.primaryActionTitle
        case .virtualCamera:
            return currentStep.primaryActionTitle
        }
    }

    func beginStartup(
        with installer: SystemExtensionInstaller,
        onReady: @escaping () -> Void
    ) {
        self.onReady = onReady
        didSignalReady = false
        syncStoredAuthorizationState(installer: installer)
        advance(with: installer)
    }

    func requestCurrentPermission(with installer: SystemExtensionInstaller) {
        guard let currentStep, !isRequesting else { return }
        statusText = ""

        switch currentStep {
        case .camera:
            requestCameraAccess(with: installer)
        case .microphone:
            requestMicrophoneAccess(with: installer)
        case .virtualCamera:
            requestVirtualCameraInstall(with: installer)
        }
    }

    func handleInstallerState(
        _ state: SystemExtensionInstallationState,
        installer: SystemExtensionInstaller
    ) {
        guard currentStep == .virtualCamera || StartupPermissionDefaults.wasVirtualCameraInstallRequested else {
            return
        }

        switch state {
        case .installed:
            isRequesting = false
            StartupPermissionDefaults.setVirtualCameraInstalled(true)
            statusText = "Virtual camera installed."
            advance(with: installer)
        case .awaitingApproval:
            isRequesting = false
            currentStep = .virtualCamera
            didAutomaticallyRetryVirtualCameraInstall = false
            StartupPermissionDefaults.setVirtualCameraInstalled(false)
            statusText = "Approve the virtual camera in System Settings, then return to Emyn."
        case .requiresReboot:
            isRequesting = false
            StartupPermissionDefaults.setVirtualCameraInstalled(true)
            statusText = "The virtual camera will finish after restart."
            advance(with: installer)
        case .failed(let message):
            isRequesting = false
            currentStep = .virtualCamera
            didAutomaticallyRetryVirtualCameraInstall = false
            statusText = message
        case .installing:
            isRequesting = true
            statusText = "Installing virtual camera..."
        case .notInstalled, .removing, .requestCompleted:
            break
        }
    }

    private func requestCameraAccess(with installer: SystemExtensionInstaller) {
        switch cameraAuthorizationStatus {
        case .authorized:
            StartupPermissionDefaults.setCameraGranted(true)
            advance(with: installer)
        case .notDetermined:
            isRequesting = true
            statusText = "Waiting for the camera permission prompt..."
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRequesting = false
                    StartupPermissionDefaults.setCameraGranted(granted)
                    self.statusText = granted ? "" : "Camera access was not granted."
                    self.advance(with: installer)
                }
            }
        case .denied, .restricted:
            openSettings(for: .camera)
            statusText = "Enable camera access in System Settings, then return to Emyn."
        @unknown default:
            statusText = "Camera access is unavailable."
        }
    }

    private func requestMicrophoneAccess(with installer: SystemExtensionInstaller) {
        switch microphoneAuthorizationStatus {
        case .authorized:
            StartupPermissionDefaults.setMicrophoneGranted(true)
            advance(with: installer)
        case .notDetermined:
            isRequesting = true
            statusText = "Waiting for the microphone permission prompt..."
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRequesting = false
                    StartupPermissionDefaults.setMicrophoneGranted(granted)
                    self.statusText = granted ? "" : "Microphone access was not granted."
                    self.advance(with: installer)
                }
            }
        case .denied, .restricted:
            openSettings(for: .microphone)
            statusText = "Enable microphone access in System Settings, then return to Emyn."
        @unknown default:
            statusText = "Microphone access is unavailable."
        }
    }

    private func requestVirtualCameraInstall(with installer: SystemExtensionInstaller) {
        isRequesting = true
        statusText = "Installing virtual camera..."
        StartupPermissionDefaults.setVirtualCameraInstallRequested(true)
        installer.activate()
    }

    private func advance(with installer: SystemExtensionInstaller) {
        syncStoredAuthorizationState(installer: installer)

        if cameraAuthorizationStatus != .authorized {
            currentStep = .camera
            return
        }

        if microphoneAuthorizationStatus != .authorized {
            currentStep = .microphone
            return
        }

        if !StartupPermissionDefaults.wasVirtualCameraInstalled {
            currentStep = .virtualCamera
            retryVirtualCameraInstallIfNeeded(with: installer)
            return
        }

        currentStep = nil
        isRequesting = false
        statusText = ""
        retryVirtualCameraInstallIfNeeded(with: installer)
        signalReadyIfNeeded()
    }

    private func retryVirtualCameraInstallIfNeeded(with installer: SystemExtensionInstaller) {
        guard StartupPermissionDefaults.wasVirtualCameraInstallRequested,
              !didAutomaticallyRetryVirtualCameraInstall else {
            return
        }

        didAutomaticallyRetryVirtualCameraInstall = true
        installer.activate()
    }

    private func signalReadyIfNeeded() {
        guard !didSignalReady else { return }
        didSignalReady = true
        onReady?()
    }

    private func syncStoredAuthorizationState(installer: SystemExtensionInstaller) {
        StartupPermissionDefaults.setCameraGranted(cameraAuthorizationStatus == .authorized)
        StartupPermissionDefaults.setMicrophoneGranted(microphoneAuthorizationStatus == .authorized)

        if isVirtualCameraAvailable {
            installer.noteVirtualCameraAvailable()
        }
    }

    private var cameraAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    private var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private var isVirtualCameraAvailable: Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices.contains { $0.localizedName == SharedFrameConfiguration.virtualCameraName }
    }

    private func openSettings(for step: StartupPermissionStep) {
        guard let url = step.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

struct StartupPermissionWizardView: View {
    @ObservedObject var coordinator: StartupPermissionCoordinator
    @ObservedObject var installer: SystemExtensionInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let step = coordinator.currentStep {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(coordinator.progressTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(step.title)
                            .font(.title2.weight(.semibold))
                    }
                }

                Text(step.explanation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !coordinator.statusText.isEmpty {
                    Text(coordinator.statusText)
                        .font(.callout)
                        .foregroundStyle(step == .virtualCamera && installer.needsUserApproval ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()

                    Button {
                        coordinator.requestCurrentPermission(with: installer)
                    } label: {
                        if coordinator.isRequesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(coordinator.primaryActionTitle, systemImage: step.systemImage)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.isRequesting)
                }
            }
        }
        .padding(28)
        .frame(width: 460, alignment: .leading)
    }
}
