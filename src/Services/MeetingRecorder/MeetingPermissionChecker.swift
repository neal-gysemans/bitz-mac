@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import Speech

// MARK: - Permission Checking Protocol & System Implementation

public protocol MeetingPermissionChecking: Sendable {
    func currentPermissions() -> MeetingPermissionState
    func requestPermissions(
        captureMicrophone: Bool,
        captureSystemAudio: Bool,
        transcribe: Bool
    ) async -> MeetingPermissionState
    /// `currentPermissions` after any async re-check that is too slow for a view body (Settings `.onAppear`).
    func refreshedPermissions() async -> MeetingPermissionState
}

public extension MeetingPermissionChecking {
    func refreshedPermissions() async -> MeetingPermissionState { currentPermissions() }
}

public struct SystemMeetingPermissionChecker: MeetingPermissionChecking {
    /// `CGPreflightScreenCaptureAccess` stays false until relaunch, so remember that access was already requested.
    static let screenCaptureRequestedKey = MeetingSettingsStore.keyPrefix + "screenCaptureRequested"

    /// Last ScreenCaptureKit probe answer: `CGPreflightScreenCaptureAccess` can stay false for a granted app
    /// (seen on macOS 26 with an ad-hoc signed build), and `currentPermissions` must stay synchronous.
    static let screenCaptureProbeGrantedKey = MeetingSettingsStore.keyPrefix + "screenCaptureProbeGranted"

    /// UserDefaults is thread-safe but not marked Sendable.
    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let preflightScreenCapture: @Sendable () -> Bool
    private let requestScreenCapture: @Sendable () -> Bool
    /// True when ScreenCaptureKit lists shareable content, i.e. TCC lets this app capture.
    private let probeScreenCapture: @Sendable () async -> Bool

    public init(
        userDefaults: UserDefaults = .standard,
        preflightScreenCapture: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestScreenCapture: @escaping @Sendable () -> Bool = { CGRequestScreenCaptureAccess() },
        probeScreenCapture: @escaping @Sendable () async -> Bool = {
            // Any error (SCStreamError.userDeclined -3801 or other) leaves the preflight answer, which is false here
            (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
        }
    ) {
        self.userDefaults = userDefaults
        self.preflightScreenCapture = preflightScreenCapture
        self.requestScreenCapture = requestScreenCapture
        self.probeScreenCapture = probeScreenCapture
    }

    /// Only called when preflight said no; caches the answer for `currentPermissions`.
    private func probeAndCache() async -> Bool {
        let granted = await probeScreenCapture()
        userDefaults.set(granted, forKey: Self.screenCaptureProbeGrantedKey)
        if granted {
            NSLog("Bitz: CGPreflightScreenCaptureAccess=false but SCShareableContent succeeded")
        }
        return granted
    }

    public func refreshedPermissions() async -> MeetingPermissionState {
        // Skip until something asked (or a probe granted), so opening Settings never raises a capture prompt
        if !preflightScreenCapture(),
           userDefaults.bool(forKey: Self.screenCaptureRequestedKey)
            || userDefaults.bool(forKey: Self.screenCaptureProbeGrantedKey) {
            _ = await probeAndCache()
        }
        return currentPermissions()
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
        if preflightScreenCapture() || userDefaults.bool(forKey: Self.screenCaptureProbeGrantedKey) {
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

        // Re-checked even when the cached probe said yes, so a revoked grant is noticed before capture
        if captureSystemAudio {
            let granted = preflightScreenCapture() ? true : await probeAndCache()
            if granted {
                state.screenAudio = .authorized
            } else {
                userDefaults.set(true, forKey: Self.screenCaptureRequestedKey)
                state.screenAudio = requestScreenCapture() ? .authorized : .denied
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
