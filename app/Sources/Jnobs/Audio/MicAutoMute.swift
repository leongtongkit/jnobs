import Foundation
import AVFoundation
import os

/// Auto-mutes the system input device when silent, unmutes when speech is
/// detected. Useful on calls — replaces the "manually toggle mute every time
/// I want to say something / hide a cough" workflow.
///
/// Approach: AVAudioEngine taps the input device, RMS is computed per buffer
/// callback, hysteresis decides speaking vs silent. Then CoreAudioVolume
/// (un)mutes the system input. We deliberately use the system mute API
/// (rather than ducking volume inside our pipeline) so behavior is symmetric
/// with the hardware mute button.
@MainActor
final class MicAutoMute: ObservableObject {
    static let shared = MicAutoMute()

    @Published private(set) var enabled: Bool = false
    @Published private(set) var rms: Float = 0
    @Published private(set) var speaking: Bool = false

    private let log = Logger(subsystem: "net.jfound.jnobs", category: "MicAutoMute")
    private let engine = AVAudioEngine()
    private var speakingSince: Date?
    private var silentSince: Date?

    /// Threshold tuned for typical built-in / USB mic gain. Linear RMS in 0..1.
    /// ~ -35 dBFS — voice should comfortably cross this, room tone shouldn't.
    private let threshold: Float = 0.018
    private let speakingDebounce: TimeInterval = 0.08
    private let silentDebounce:   TimeInterval = 0.80

    private init() {}

    func setEnabled(_ on: Bool) {
        if on == enabled { return }
        if on { start() } else { stop() }
    }

    private func start() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Sanity: AVAudioEngine sometimes returns a 0-channel format on cold start.
        guard format.channelCount > 0 else {
            log.error("input format has 0 channels; aborting auto-mute start")
            DiagSink.shared.error("MicAutoMute", "input format has 0 channels; aborting")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let value = Self.computeRMS(buffer)
            Task { @MainActor [weak self] in self?.handle(rms: value) }
        }
        do {
            try engine.start()
        } catch {
            log.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            DiagSink.shared.error("MicAutoMute", "engine start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }
        enabled = true
        log.info("auto-mute started")
        DiagSink.shared.info("MicAutoMute", "started")
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        enabled = false
        speaking = false
        speakingSince = nil
        silentSince = nil
        log.info("auto-mute stopped")
        DiagSink.shared.info("MicAutoMute", "stopped")
    }

    private func handle(rms value: Float) {
        rms = value
        let now = Date()
        if value > threshold {
            silentSince = nil
            if speakingSince == nil { speakingSince = now }
            if let s = speakingSince, now.timeIntervalSince(s) > speakingDebounce, !speaking {
                speaking = true
                if CoreAudioVolume.getMicMute() == true {
                    _ = CoreAudioVolume.setMicMute(false)
                    DiagSink.shared.info("MicAutoMute", "speech detected → unmuting")
                }
            }
        } else {
            speakingSince = nil
            if silentSince == nil { silentSince = now }
            if let s = silentSince, now.timeIntervalSince(s) > silentDebounce, speaking {
                speaking = false
                if CoreAudioVolume.getMicMute() == false {
                    _ = CoreAudioVolume.setMicMute(true)
                    DiagSink.shared.info("MicAutoMute", "silence → muting")
                }
            }
        }
    }

    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let chCount = Int(buffer.format.channelCount)
        var sumSq: Float = 0
        for ch in 0..<chCount {
            let ptr = channels[ch]
            for i in 0..<frames {
                let s = ptr[i]
                sumSq += s * s
            }
        }
        let totalSamples = Float(frames * max(1, chCount))
        return sqrtf(sumSq / totalSamples)
    }
}
