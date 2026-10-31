import Foundation
import CoreAudio
import AudioToolbox

/// Protocol defining system audio environment detection for suppression rules.
public protocol AudioEnvironmentDetecting: Sendable {
    /// Whether system audio output is currently muted or volume is at 0.
    func isSystemOutputMuted() -> Bool

    /// Whether an input device (microphone or screen capture audio) is currently active.
    func isMicrophoneOrScreenCaptureActive() -> Bool

    /// Whether macOS Focus / Do Not Disturb mode is active.
    func isFocusOrDNDActive() -> Bool
}

/// Production detector leveraging macOS CoreAudio properties.
public final class AudioEnvironmentDetector: AudioEnvironmentDetecting, @unchecked Sendable {
    public init() {}

    public func isSystemOutputMuted() -> Bool {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )

        guard status == noErr, defaultOutputDeviceID != 0 else {
            return false
        }

        // Check mute state
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &muteAddress,
            0,
            nil,
            &muteSize,
            &isMuted
        )

        if muteStatus == noErr && isMuted != 0 {
            return true
        }

        // Check master volume
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var volume: Float32 = 1.0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        let volStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &volume
        )

        if volStatus == noErr && volume <= 0.001 {
            return true
        }

        return false
    }

    public func isMicrophoneOrScreenCaptureActive() -> Bool {
        var defaultInputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultInputDeviceID
        )

        guard status == noErr, defaultInputDeviceID != 0 else {
            return false
        }

        var isRunningSomewhereAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        let runningStatus = AudioObjectGetPropertyData(
            defaultInputDeviceID,
            &isRunningSomewhereAddress,
            0,
            nil,
            &isRunningSize,
            &isRunning
        )

        return runningStatus == noErr && isRunning != 0
    }

    public func isFocusOrDNDActive() -> Bool {
        // macOS does not provide a public C/Swift API to query Do Not Disturb status
        // without private framework entitlements. We check the standard user defaults
        // notification center preference key if accessible, or return false.
        let dndDefaults = UserDefaults(suiteName: "com.apple.controlcenter")
        if let dndActive = dndDefaults?.bool(forKey: "NSStatusItem Visible Item-0") {
            return dndActive
        }
        return false
    }
}

/// Deterministic mock for unit testing audio suppression scenarios in headless CI.
public final class MockAudioEnvironmentDetector: AudioEnvironmentDetecting, @unchecked Sendable {
    public var isMuted: Bool = false
    public var isMicActive: Bool = false
    public var isDNDActive: Bool = false

    public init(isMuted: Bool = false, isMicActive: Bool = false, isDNDActive: Bool = false) {
        self.isMuted = isMuted
        self.isMicActive = isMicActive
        self.isDNDActive = isDNDActive
    }

    public func isSystemOutputMuted() -> Bool {
        isMuted
    }

    public func isMicrophoneOrScreenCaptureActive() -> Bool {
        isMicActive
    }

    public func isFocusOrDNDActive() -> Bool {
        isDNDActive
    }
}
