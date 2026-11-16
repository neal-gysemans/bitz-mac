import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Audio Device Detecting Protocol & Implementations (#198)

/// Protocol for monitoring the active audio output device (speakers, headphones, external displays, or virtual drivers).
public protocol AudioDeviceDetecting: AnyObject, Sendable {
    /// Current snapshot of the active audio output device.
    var currentOutputDevice: AudioOutputDeviceInfo { get }

    /// Callback invoked when the default output device changes on macOS.
    var onOutputDeviceChanged: (@Sendable (AudioOutputDeviceInfo) -> Void)? { get set }

    /// Refreshes the currently active output device synchronously.
    @discardableResult
    func refreshOutputDevice() -> AudioOutputDeviceInfo
}

/// Production implementation leveraging macOS CoreAudio HAL properties and property listener blocks (#198).
public final class SystemAudioDeviceDetector: AudioDeviceDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedOutputDevice: AudioOutputDeviceInfo
    private var listenerInstalled = false
    private var changeHandler: (@Sendable (AudioOutputDeviceInfo) -> Void)?
    private let listenerQueue = DispatchQueue(label: "com.bitz.audiodevicedetector", qos: .utility)

    public var currentOutputDevice: AudioOutputDeviceInfo {
        lock.withLock { cachedOutputDevice }
    }

    public var onOutputDeviceChanged: (@Sendable (AudioOutputDeviceInfo) -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    public init() {
        self.cachedOutputDevice = Self.queryDefaultOutputDevice()
        installPropertyListener()
    }

    deinit {
        removePropertyListener()
    }

    @discardableResult
    public func refreshOutputDevice() -> AudioOutputDeviceInfo {
        let updated = Self.queryDefaultOutputDevice()
        lock.withLock { cachedOutputDevice = updated }
        return updated
    }

    private func installPropertyListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue
        ) { [weak self] _, _ in
            guard let self else { return }
            let updated = self.refreshOutputDevice()
            let handler = self.lock.withLock { self.changeHandler }
            Task { @MainActor in
                handler?(updated)
            }
        }

        if status == noErr {
            listenerInstalled = true
        }
    }

    private func removePropertyListener() {
        guard listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Pass nil or standard block removal: CoreAudio removes all blocks for this client on that address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            { _, _ in }
        )
        listenerInstalled = false
    }

    // MARK: - CoreAudio Hardware Querying

    public static func queryDefaultOutputDevice() -> AudioOutputDeviceInfo {
        var defaultOutputID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &defaultOutputID
        )

        guard status == noErr, defaultOutputID != 0 else {
            return .defaultFallback
        }

        return inspectDevice(id: defaultOutputID)
    }

    public static func inspectDevice(id: AudioDeviceID) -> AudioOutputDeviceInfo {
        // Query Name
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
        }
        let resolvedName = (name as String).trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = resolvedName.isEmpty ? "Unknown Audio Device" : resolvedName

        // Query Transport Type
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &transportSize, &transport)
        let transportCode = decodeTransportCode(transport)

        // Query Nominal Sample Rate
        var nominalRate: Float64 = 48_000
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rateSize, &nominalRate)

        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let deviceType = classifyDevice(name: deviceName, transport: transport)
        let isVirtual = deviceType == .virtualDriver

        return AudioOutputDeviceInfo(
            id: id,
            name: deviceName,
            transportType: transportCode,
            deviceType: deviceType,
            sampleRate: nominalRate > 0 ? nominalRate : 48_000,
            isBluetooth: isBluetooth,
            isVirtual: isVirtual
        )
    }

    public static func classifyDevice(name: String, transport: UInt32) -> AudioOutputDeviceType {
        let lowerName = name.lowercased()

        // 1. Virtual drivers (Teams, Zoom, BlackHole, Loopback, etc.)
        if transport == kAudioDeviceTransportTypeVirtual
            || lowerName.contains("teams")
            || lowerName.contains("blackhole")
            || lowerName.contains("loopback")
            || lowerName.contains("zoom")
            || lowerName.contains("soundflower")
            || lowerName.contains("virtual") {
            return .virtualDriver
        }

        // 2. Bluetooth Headsets / Headphones
        if transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || lowerName.contains("airpods")
            || lowerName.contains("headphone")
            || lowerName.contains("headset")
            || lowerName.contains("buds")
            || lowerName.contains("wh-")
            || lowerName.contains("wf-") {
            return .headphones
        }

        // 3. External Displays (DisplayPort / HDMI)
        if transport == kAudioDeviceTransportTypeDisplayPort
            || transport == kAudioDeviceTransportTypeHDMI
            || lowerName.contains("display")
            || lowerName.contains("monitor")
            || lowerName.contains("tv")
            || lowerName.contains("hdr") {
            return .externalDisplay
        }

        // 4. USB Audio Devices
        if transport == kAudioDeviceTransportTypeUSB {
            if lowerName.contains("headphone") || lowerName.contains("headset") {
                return .headphones
            }
            return .usbDevice
        }

        // 5. Built-in Speakers / Headphone jack
        if transport == kAudioDeviceTransportTypeBuiltIn {
            if lowerName.contains("headphone") {
                return .headphones
            }
            return .builtInSpeakers
        }

        return .other
    }

    public static func decodeTransportCode(_ transport: UInt32) -> String {
        guard transport > 0 else { return "none" }
        let chars = [
            Character(UnicodeScalar((transport >> 24) & 0xff) ?? " "),
            Character(UnicodeScalar((transport >> 16) & 0xff) ?? " "),
            Character(UnicodeScalar((transport >> 8) & 0xff) ?? " "),
            Character(UnicodeScalar(transport & 0xff) ?? " ")
        ]
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Mock Implementation for Deterministic Unit Testing

public final class MockAudioDeviceDetector: AudioDeviceDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var device: AudioOutputDeviceInfo
    public var onOutputDeviceChanged: (@Sendable (AudioOutputDeviceInfo) -> Void)?
    public var refreshCallCount = 0

    public var currentOutputDevice: AudioOutputDeviceInfo {
        get { lock.withLock { device } }
        set { lock.withLock { device = newValue } }
    }

    public init(device: AudioOutputDeviceInfo = .defaultFallback) {
        self.device = device
    }

    @discardableResult
    public func refreshOutputDevice() -> AudioOutputDeviceInfo {
        lock.withLock {
            refreshCallCount += 1
            return device
        }
    }

    public func simulateDeviceChange(to newDevice: AudioOutputDeviceInfo) {
        lock.withLock { device = newDevice }
        onOutputDeviceChanged?(newDevice)
    }
}
