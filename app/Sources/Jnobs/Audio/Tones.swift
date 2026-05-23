import Foundation
import AVFoundation
import CoreAudio
import os

/// Plays a short test tone so the user can verify which output device an audio
/// route is actually pointing at. Plays *directly* through the chosen device —
/// bypasses the process-tap pipeline, because we're testing the destination,
/// not the plumbing.
@MainActor
final class TonePinger {
    static let shared = TonePinger()

    private let log = Logger(subsystem: "net.jfound.jnobs", category: "Tones")
    /// Strong refs to engines currently playing — released when their buffer finishes.
    private var liveEngines: [AVAudioEngine] = []

    /// Play a ~280 ms 440 Hz sine through `deviceUID` (nil = system default).
    func play(deviceUID: String?) {
        let engine = AVAudioEngine()

        if let uid = deviceUID, let id = findDevice(uid: uid) {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(id)
            } catch {
                log.error("setDeviceID(\(uid, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.outputNode, format: format)

        let durationSeconds = 0.28
        let frames = AVAudioFrameCount(durationSeconds * format.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = frames

        let omega = 2 * .pi * 440 / format.sampleRate
        let fadeFrames = Int(0.012 * format.sampleRate)
        let channels = Int(format.channelCount)
        let n = Int(frames)
        for i in 0..<n {
            let leftToEnd = n - i
            let env: Float
            if i < fadeFrames {
                env = Float(i) / Float(fadeFrames)
            } else if leftToEnd < fadeFrames {
                env = Float(leftToEnd) / Float(fadeFrames)
            } else {
                env = 1.0
            }
            let sample = Float(sin(Double(i) * omega) * 0.25) * env
            for ch in 0..<channels {
                channelData[ch][i] = sample
            }
        }

        do {
            try engine.start()
        } catch {
            log.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        liveEngines.append(engine)

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let engine = engine else { return }
                engine.stop()
                self?.liveEngines.removeAll { $0 === engine }
            }
        }
        player.play()
    }

    private func findDevice(uid: String) -> AudioDeviceID? {
        let ids = CA.array(CA.system, CA.addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
        for id in ids where AudioDevices.uid(id) == uid { return id }
        return nil
    }
}
