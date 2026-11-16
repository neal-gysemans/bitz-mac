import Foundation
import CoreAudio
import XCTest
@testable import BitzCore

final class AudioDeviceDetectorTests: XCTestCase {

    // MARK: - Classification Tests

    func testClassifyDevice_HeadphonesAndHeadsets() {
        // Bluetooth transport ('blue')
        let transportBT: UInt32 = 0x626c7565
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "WH-CH720N", transport: transportBT),
            .headphones
        )
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "AirPods Pro", transport: transportBT),
            .headphones
        )
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "Bose QuietComfort 45", transport: transportBT),
            .headphones
        )
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "Pixel Buds Pro", transport: transportBT),
            .headphones
        )

        // USB Headset ('usb ')
        let transportUSB: UInt32 = 0x75736220
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "Jabra Evolve Headset", transport: transportUSB),
            .headphones
        )
    }

    func testClassifyDevice_VirtualDrivers() {
        let transportVirt: UInt32 = 0x76697274
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "Microsoft Teams Audio", transport: transportVirt),
            .virtualDriver
        )
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "BlackHole 2ch", transport: transportVirt),
            .virtualDriver
        )
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "Loopback Audio", transport: transportVirt),
            .virtualDriver
        )
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "ZoomAudioDevice", transport: transportVirt),
            .virtualDriver
        )
    }

    func testClassifyDevice_Displays() {
        let transportDP: UInt32 = 0x64707274 // 'dprt'
        let transportHDMI: UInt32 = 0x68646d69 // 'hdmi'
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "LG HDR 4K", transport: transportDP),
            .externalDisplay
        )
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "Dell UltraSharp Display", transport: transportHDMI),
            .externalDisplay
        )
    }

    func testClassifyDevice_BuiltInSpeakers() {
        let transportBuiltIn: UInt32 = 0x626c746e // 'bltn'
        XCTAssertEqual(
            SystemAudioDeviceDetector.classifyDevice(name: "MacBook Pro Speakers", transport: transportBuiltIn),
            .builtInSpeakers
        )
    }

    // MARK: - Communication Profile & Advisory Notices

    func testCommunicationProfileDetection() {
        let telephonyHeadset = AudioOutputDeviceInfo(
            id: 95,
            name: "WH-CH720N",
            transportType: "blue",
            deviceType: .headphones,
            sampleRate: 16_000,
            isBluetooth: true,
            isVirtual: false
        )
        XCTAssertTrue(telephonyHeadset.isCommunicationProfile)
        XCTAssertNotNil(telephonyHeadset.advisoryRoutingNotice)
        XCTAssertTrue(telephonyHeadset.advisoryRoutingNotice?.contains("telephony mode") == true)

        let a2dpHeadphones = AudioOutputDeviceInfo(
            id: 95,
            name: "WH-CH720N",
            transportType: "blue",
            deviceType: .headphones,
            sampleRate: 48_000,
            isBluetooth: true,
            isVirtual: false
        )
        XCTAssertFalse(a2dpHeadphones.isCommunicationProfile)
        XCTAssertNil(a2dpHeadphones.advisoryRoutingNotice)

        let virtualDriver = AudioOutputDeviceInfo(
            id: 73,
            name: "Microsoft Teams Audio",
            transportType: "virt",
            deviceType: .virtualDriver,
            sampleRate: 48_000,
            isBluetooth: false,
            isVirtual: true
        )
        XCTAssertFalse(virtualDriver.isCommunicationProfile)
        XCTAssertNotNil(virtualDriver.advisoryRoutingNotice)
        XCTAssertTrue(virtualDriver.advisoryRoutingNotice?.contains("Virtual audio driver") == true)
    }

    // MARK: - MockAudioDeviceDetector & MeetingRecorderService Integration

    @MainActor
    func testMeetingRecorderService_RecordsOutputDeviceInfoInMetadata() async throws {
        let suiteName = "bitz.test.audiodevice." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTests_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let settingsStore = MeetingSettingsStore(userDefaults: defaults)
        settingsStore.setMeetingsRootDirectoryURL(tempFolder)
        settingsStore.setConsentAcknowledged(true)

        let mockDevice = AudioOutputDeviceInfo(
            id: 95,
            name: "Sony WH-CH720N",
            transportType: "blue",
            deviceType: .headphones,
            sampleRate: 16_000,
            isBluetooth: true,
            isVirtual: false
        )
        let mockDetector = MockAudioDeviceDetector(device: mockDevice)
        let captureEngine = MockMeetingAudioCaptureEngine()

        let service = MeetingRecorderService(
            settingsStore: settingsStore,
            captureEngine: captureEngine,
            transcriptionService: MockMeetingTranscriptionService(),
            permissionChecker: MockMeetingPermissionChecker(
                state: MeetingPermissionState(microphone: .authorized, screenAudio: .authorized, speechRecognition: .authorized)
            ),
            audioDeviceDetector: mockDetector
        )

        XCTAssertEqual(service.activeOutputDevice.name, "Sony WH-CH720N")
        XCTAssertEqual(service.activeOutputDevice.deviceType, .headphones)

        // Start and stop recording
        await service.startRecording()
        XCTAssertTrue(service.isRecording)
        await service.stopRecording(transcribe: false)

        guard let lastResult = service.lastCompletedResult else {
            XCTFail("Expected lastCompletedResult")
            return
        }

        let metadataData = try Data(contentsOf: lastResult.metadataFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MeetingRecordingMetadata.self, from: metadataData)

        XCTAssertEqual(metadata.outputDeviceName, "Sony WH-CH720N")
        XCTAssertEqual(metadata.outputDeviceType, "headphones")

        // Test dynamic device update
        let switchedDevice = AudioOutputDeviceInfo(
            id: 83,
            name: "MacBook Pro Speakers",
            transportType: "bltn",
            deviceType: .builtInSpeakers,
            sampleRate: 48_000,
            isBluetooth: false,
            isVirtual: false
        )
        mockDetector.simulateDeviceChange(to: switchedDevice)

        // Give MainActor task a tick
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.activeOutputDevice.name, "MacBook Pro Speakers")
        XCTAssertEqual(service.activeOutputDevice.deviceType, .builtInSpeakers)
    }

    func testTransportCodeDecoding() {
        XCTAssertEqual(SystemAudioDeviceDetector.decodeTransportCode(0x626c7565), "blue")
        XCTAssertEqual(SystemAudioDeviceDetector.decodeTransportCode(0x626c746e), "bltn")
        XCTAssertEqual(SystemAudioDeviceDetector.decodeTransportCode(0x76697274), "virt")
        XCTAssertEqual(SystemAudioDeviceDetector.decodeTransportCode(0), "none")
    }

    func testSystemAudioDeviceDetector_LiveQueryDoesNotCrash() {
        let detector = SystemAudioDeviceDetector()
        let device = detector.currentOutputDevice
        XCTAssertFalse(device.name.isEmpty)
        XCTAssertTrue(device.sampleRate > 0)
    }
}
