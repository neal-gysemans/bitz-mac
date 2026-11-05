@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Speech

// MARK: - Permission Checking Protocol & System Implementation

public protocol MeetingPermissionChecking: Sendable {
    func currentPermissions() -> MeetingPermissionState
    func requestPermissions(
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        transcribe: Bool
    ) async -> MeetingPermissionState
}

public struct SystemMeetingPermissionChecker: MeetingPermissionChecking {
    /// `CGPreflightScreenCaptureAccess` stays false until relaunch, so remember that access was already requested.
    static let screenCaptureRequestedKey = MeetingSettingsStore.keyPrefix + "screenCaptureRequested"

    /// UserDefaults is thread-safe but not marked Sendable.
    nonisolated(unsafe) private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func currentPermissions() -> MeetingPermissionState {
        let micStatus: MeetingPermissionState.Status
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micStatus = .authorized
        case .denied, .restricted:
            micStatus = .denied
        case .notDetermined:
            micStatus = .notDetermined
        @unknown default:
            micStatus = .notDetermined
        }

        let screenStatus: MeetingPermissionState.Status
        if CGPreflightScreenCaptureAccess() {
            screenStatus = .authorized
        } else {
            screenStatus = userDefaults.bool(forKey: Self.screenCaptureRequestedKey) ? .denied : .notDetermined
        }

        let speechStatus: MeetingPermissionState.Status
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechStatus = .authorized
        case .denied, .restricted:
            speechStatus = .denied
        case .notDetermined:
            speechStatus = .notDetermined
        @unknown default:
            speechStatus = .notDetermined
        }

        return MeetingPermissionState(
            microphone: micStatus,
            screenAudio: screenStatus,
            speechRecognition: speechStatus
        )
    }

    public func requestPermissions(
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        transcribe: Bool
    ) async -> MeetingPermissionState {
        var state = currentPermissions()

        if captureMicrophone && state.microphone == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            state.microphone = granted ? .authorized : .denied
        }

        if captureSystemAudio && state.screenAudio != .authorized {
            if CGPreflightScreenCaptureAccess() {
                state.screenAudio = .authorized
            } else {
                userDefaults.set(true, forKey: Self.screenCaptureRequestedKey)
                let granted = CGRequestScreenCaptureAccess()
                state.screenAudio = granted ? .authorized : .denied
            }
        }

        if transcribe && state.speechRecognition == .notDetermined {
            let authStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            state.speechRecognition = (authStatus == .authorized) ? .authorized : .denied
        }

        return state
    }
}
