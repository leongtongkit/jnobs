import Foundation
import SwiftUI

/// Polls the system's master output volume and mute state at 4 Hz, exposing
/// them as `@Published` so the menubar icon can reflect changes initiated by
/// any app (Mac volume keys, other apps, etc.), not just Jnobs's own knob.
///
/// Cheap: two HAL property reads per tick, no allocation. We could replace
/// this with a Core Audio property listener for zero overhead, but the
/// listener would still need debouncing and the polling cost is negligible.
@MainActor
final class MasterVolumeMonitor: ObservableObject {
    static let shared = MasterVolumeMonitor()

    @Published private(set) var volume: Float = 0
    @Published private(set) var muted: Bool = false

    private var timer: Timer?

    private init() { start() }

    private func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        let v = CoreAudioVolume.getMasterVolume() ?? 0
        let m = CoreAudioVolume.getMasterMute() ?? false
        if abs(v - volume) > 0.003 { volume = v }
        if m != muted { muted = m }
    }
}
