import Foundation
import CoreAudio

// MARK: - Audio Output Device Classification & Info Models (#198)

/// Classifies the functional category of an audio output device connected to macOS.
public enum AudioOutputDeviceType: String, Codable, CaseIterable, Sendable {
    case headphones
    case builtInSpeakers
    case externalDisplay
    case usbDevice
    case virtualDriver
    case other

    public var displayName: String {
        switch self {
        case .headphones:
            return "Headphones / Headset"
        case .builtInSpeakers:
            return "Built-in Speakers"
        case .externalDisplay:
            return "External Display"
        case .usbDevice:
            return "USB Audio Device"
        case .virtualDriver:
            return "Virtual Audio Driver"
        case .other:
            return "Audio Output"
        }
    }

    public var systemImage: String {
        switch self {
        case .headphones:
            return "headphones"
        case .builtInSpeakers:
            return "speaker.wave.2.fill"
        case .externalDisplay:
            return "display"
        case .usbDevice:
            return "cable.connector"
        case .virtualDriver:
            return "waveform.badge.magnifyingglass"
        case .other:
            return "speaker.fill"
        }
    }
}

/// Information snapshot of the currently selected audio output device on macOS (#198).
public struct AudioOutputDeviceInfo: Codable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let transportType: String
    public let deviceType: AudioOutputDeviceType
    public let sampleRate: Double
    public let isBluetooth: Bool
    public let isVirtual: Bool

    public init(
        id: UInt32,
        name: String,
        transportType: String,
        deviceType: AudioOutputDeviceType,
        sampleRate: Double = 48_000,
        isBluetooth: Bool = false,
        isVirtual: Bool = false
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.deviceType = deviceType
        self.sampleRate = sampleRate
        self.isBluetooth = isBluetooth
        self.isVirtual = isVirtual
    }

    /// Whether this device is operating in low-bandwidth telephony / communication mode (e.g. SCO 16kHz mono).
    public var isCommunicationProfile: Bool {
        isBluetooth && sampleRate <= 16_000
    }

    /// Advisory notice when audio routing could isolate call audio away from standard desktop ScreenCaptureKit capture.
    public var advisoryRoutingNotice: String? {
        if isVirtual {
            return "Virtual audio driver detected (\(name)). Meeting apps routing audio exclusively through virtual drivers may not be heard by standard screen audio recording."
        }
        if isCommunicationProfile {
            return "Bluetooth headset (\(name)) is in telephony mode (16 kHz). In Teams/Zoom, verify 'Speaker' is set to System Default or this headset."
        }
        return nil
    }

    public static let defaultFallback = AudioOutputDeviceInfo(
        id: 0,
        name: "Default System Audio",
        transportType: "bltn",
        deviceType: .builtInSpeakers,
        sampleRate: 48_000,
        isBluetooth: false,
        isVirtual: false
    )
}
