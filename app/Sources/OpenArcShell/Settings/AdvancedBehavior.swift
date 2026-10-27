import Foundation
import AppKit
import Combine

// Settings ▸ Advanced switches that change how the app feels (plan B84): sound effects, haptic
// feedback when reordering tabs, and window dragging from the top of webpages. [03 §Advanced]
// observed the three toggles and their defaults (all on). The sounds are our own, synthesized at
// run time: [00 §音效与触感] says Arc's sound content is not copied. Which actions play a sound
// is not recorded (unknown); ours: copying the current URL and clearing Today (inferred).

/// The three switches as one observable object, shared by every window (an incognito controller
/// uses its parent's), so the Settings window and every browser window stay in step.
@MainActor
public final class AdvancedBehaviorSettings: ObservableObject {
    private let preferences: AppPreferences

    /// "Play Open Arc sound effects". [03 §Advanced] observed, on by default.
    @Published public var playsSoundEffects: Bool {
        didSet { if playsSoundEffects != oldValue { preferences.playsSoundEffects = playsSoundEffects } }
    }

    /// "Haptic feedback when reordering tabs". [03 §Advanced] observed, on by default.
    @Published public var playsReorderHaptics: Bool {
        didSet { if playsReorderHaptics != oldValue { preferences.playsReorderHaptics = playsReorderHaptics } }
    }

    /// "Allow window dragging from the top of webpages". [03 §Advanced] observed, on by default;
    /// [06 §13] observed the drag handle at the top of the page area.
    @Published public var allowsWindowDragFromPageTop: Bool {
        didSet { if allowsWindowDragFromPageTop != oldValue { preferences.allowsWindowDragFromPageTop = allowsWindowDragFromPageTop } }
    }

    public init(preferences: AppPreferences) {
        self.preferences = preferences
        playsSoundEffects = preferences.playsSoundEffects
        playsReorderHaptics = preferences.playsReorderHaptics
        allowsWindowDragFromPageTop = preferences.allowsWindowDragFromPageTop
    }
}

// MARK: - Sounds

/// Our own short interface sounds. Each is a few synthesized sine partials with a quick decay,
/// encoded as a 16-bit mono WAV (`FeedbackSoundSynth`). Nothing is bundled or copied.
public enum FeedbackSound: String, CaseIterable, Sendable {
    /// The current URL was copied (Edit ▸ Copy URL, the command bar, the toolbar's copy button).
    case copy
    /// Today was cleared (↓ Clear, ⇧⌘K).
    case clear
}

/// Synthesizes `FeedbackSound`s. Pure: the same sound gives the same bytes.
public enum FeedbackSoundSynth {
    public static let sampleRate = 44_100

    /// One tone segment: a sine glide from `startHz` to `endHz` with an exponential decay.
    struct Segment {
        var startHz: Double
        var endHz: Double
        var duration: Double
        var gain: Double
    }

    static func segments(for sound: FeedbackSound) -> [Segment] {
        switch sound {
        case .copy:
            // Two quick rising notes.
            return [Segment(startHz: 880, endHz: 880, duration: 0.055, gain: 0.22),
                    Segment(startHz: 1_320, endHz: 1_320, duration: 0.085, gain: 0.20)]
        case .clear:
            // One soft downward glide.
            return [Segment(startHz: 760, endHz: 260, duration: 0.18, gain: 0.22)]
        }
    }

    /// 16-bit signed little-endian mono samples of `sound`.
    public static func samples(for sound: FeedbackSound) -> [Int16] {
        var out: [Int16] = []
        for segment in segments(for: sound) {
            let count = Int(segment.duration * Double(sampleRate))
            var phase = 0.0
            for index in 0..<count {
                let t = Double(index) / Double(count)
                let hz = segment.startHz + (segment.endHz - segment.startHz) * t
                phase += 2 * Double.pi * hz / Double(sampleRate)
                // 3 ms attack, then an exponential decay to about 2 % at the segment's end.
                let attack = min(1, Double(index) / (0.003 * Double(sampleRate)))
                let envelope = attack * exp(-4 * t)
                let value = (sin(phase) + 0.25 * sin(2 * phase)) / 1.25 * envelope * segment.gain
                out.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
            }
        }
        return out
    }

    /// A complete RIFF/WAVE file of `sound`.
    public static func wav(for sound: FeedbackSound) -> Data {
        let samples = samples(for: sound)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                       // fmt chunk size
        append(UInt16(1))                        // PCM
        append(UInt16(1))                        // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))           // byte rate
        append(UInt16(2))                        // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples { append(sample) }
        return data
    }
}

// MARK: - Output

/// Where sounds and haptics go. Injected through `AppDependencies`, so tests and previews never
/// make a sound or tap the trackpad.
@MainActor
public protocol FeedbackOutput: AnyObject, Sendable {
    func play(_ sound: FeedbackSound)
    /// A light tap on a Force Touch trackpad.
    func performHaptic()
}

/// Does nothing (the default for tests, previews and `.fake()`).
@MainActor
public final class SilentFeedbackOutput: FeedbackOutput {
    public nonisolated init() {}
    public func play(_ sound: FeedbackSound) {}
    public func performHaptic() {}
}

/// Records what would have played (tests).
@MainActor
public final class RecordingFeedbackOutput: FeedbackOutput {
    public private(set) var sounds: [FeedbackSound] = []
    public private(set) var haptics = 0
    public nonisolated init() {}
    public func play(_ sound: FeedbackSound) { sounds.append(sound) }
    public func performHaptic() { haptics += 1 }
}

/// The real output: `NSSound` for the synthesized WAVs and `NSHapticFeedbackManager` for haptics.
@MainActor
public final class SystemFeedbackOutput: FeedbackOutput {
    private var cache: [FeedbackSound: NSSound] = [:]

    public nonisolated init() {}

    public func play(_ sound: FeedbackSound) {
        let player = cache[sound] ?? NSSound(data: FeedbackSoundSynth.wav(for: sound))
        guard let player else { return }
        cache[sound] = player
        player.stop()
        player.play()
    }

    /// `.alignment` is the system pattern for things snapping into place (a dropped row). inferred.
    public func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// Plays feedback when the matching Settings ▸ Advanced switch is on. One per app (on the
/// workspace controller; an incognito controller uses its parent's).
@MainActor
public final class FeedbackPlayer {
    public let settings: AdvancedBehaviorSettings
    let output: any FeedbackOutput

    init(settings: AdvancedBehaviorSettings, output: any FeedbackOutput) {
        self.settings = settings
        self.output = output
    }

    /// Plays `sound` when "Play Open Arc sound effects" is on.
    public func play(_ sound: FeedbackSound) {
        guard settings.playsSoundEffects else { return }
        output.play(sound)
    }

    /// A sidebar drag moved to a new drop position: one haptic tap when "Haptic feedback when
    /// reordering tabs" is on. [03 §Advanced] observed toggle; when it fires is inferred (B68).
    public func reorderHaptic() {
        guard settings.playsReorderHaptics else { return }
        output.performHaptic()
    }
}
