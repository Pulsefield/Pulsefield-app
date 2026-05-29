import AVFoundation
import Foundation

public protocol MicrophonePermissionProviding: Sendable {
    func currentStatus() async -> MicrophonePermissionStatus
    func requestAccess() async -> MicrophonePermissionStatus
}

public actor MicrophonePermissionService: MicrophonePermissionProviding {
    public init() {}

    public func currentStatus() async -> MicrophonePermissionStatus {
        map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAccess() async -> MicrophonePermissionStatus {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        let mapped = map(current)

        guard mapped == .undetermined else {
            return mapped
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if granted {
            return .authorized
        }

        return map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func map(_ status: AVAuthorizationStatus) -> MicrophonePermissionStatus {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .restricted
        }
    }
}

public actor MockMicrophonePermissionService: MicrophonePermissionProviding {
    private var status: MicrophonePermissionStatus

    public init(status: MicrophonePermissionStatus = .authorized) {
        self.status = status
    }

    public func currentStatus() async -> MicrophonePermissionStatus {
        status
    }

    public func requestAccess() async -> MicrophonePermissionStatus {
        if status == .undetermined {
            status = .authorized
        }

        return status
    }

    public func overrideStatus(_ newStatus: MicrophonePermissionStatus) async {
        status = newStatus
    }
}
