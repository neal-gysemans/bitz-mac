import Foundation

/// Defines the contract for playing cyber sound effects, purr loops, and state audio in Bitz.
///
/// Decouples audio playback triggers from `AVFoundation` so state machines, monitors,
/// and views can be tested deterministically in headless CI without physical audio hardware.
@MainActor
public protocol CyberAudioPlaying: AnyObject {
    /// Plays a discrete one-shot sound effect if master audio and the event toggle are enabled.
    func play(_ event: CyberSoundEvent)

    /// Plays a sound effect with an optional flag to bypass cooldown/rate-limit checks (for UI previews).
    func play(_ event: CyberSoundEvent, bypassCooldown: Bool)

    /// Controls whether the continuous mechanical purr loop is active.
    func setPurring(_ on: Bool)

    /// Immediately halts all active playback, loops, and faders.
    func stopAll()

    /// Current purring loop status.
    var isPurring: Bool { get }
}

public extension CyberAudioPlaying {
    func play(_ event: CyberSoundEvent) {
        play(event, bypassCooldown: false)
    }
}

/// A test spy conforming to `CyberAudioPlaying` for unit testing state machines,
/// cooldown timers, and suppression logic without audio hardware.
@MainActor
public final class SpyCyberAudioPlayer: CyberAudioPlaying {
    public private(set) var playedEvents: [CyberSoundEvent] = []
    public private(set) var purrHistory: [Bool] = []
    public private(set) var stopAllCallCount: Int = 0
    public var isPurring: Bool = false

    public init() {}

    public func play(_ event: CyberSoundEvent, bypassCooldown: Bool) {
        playedEvents.append(event)
    }

    public func setPurring(_ on: Bool) {
        isPurring = on
        purrHistory.append(on)
    }

    public func stopAll() {
        stopAllCallCount += 1
        isPurring = false
    }

    public func reset() {
        playedEvents.removeAll()
        purrHistory.removeAll()
        stopAllCallCount = 0
        isPurring = false
    }
}
