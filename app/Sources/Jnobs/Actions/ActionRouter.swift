import Foundation
import AppKit
import os

/// Routes device events to the actions defined in the current config.
@MainActor
final class ActionRouter {
    private let log = Logger(subsystem: "net.jfound.jnobs", category: "Actions")
    private(set) var config: AppConfig
    private weak var deviceManager: DeviceManager?

    /// Cached UI state for LED rendering.
    private(set) var systemMuted: Bool = false
    private(set) var micMuted: Bool = false
    /// Multiplier for all LED brightness, set by lightBrightness knob (0..1).
    private(set) var ledBrightness: Double = 1.0

    let tapRouter = TapRouter()

    init(config: AppConfig, deviceManager: DeviceManager) {
        self.config = config
        self.deviceManager = deviceManager
        // Prime mute state from system.
        self.systemMuted = CoreAudioVolume.getMasterMute() ?? false
        self.micMuted = CoreAudioVolume.getMicMute() ?? false
        applyAppRoutes(cfg: config)
        MicAutoMute.shared.setEnabled(config.autoMuteMic)
    }

    func updateConfig(_ cfg: AppConfig) {
        let oldRoutes = config.appRoutes
        let oldAutoMute = config.autoMuteMic
        self.config = cfg
        ConfigStore.save(cfg)
        if cfg.appRoutes != oldRoutes { applyAppRoutes(cfg: cfg) }
        if cfg.autoMuteMic != oldAutoMute {
            MicAutoMute.shared.setEnabled(cfg.autoMuteMic)
        }
    }

    /// Reconcile TapRouter output routes with config.
    private func applyAppRoutes(cfg: AppConfig) {
        let wanted = Set(cfg.appRoutes.map(\.bundleID))
        for route in cfg.appRoutes {
            tapRouter.setOutput(bundleID: route.bundleID, deviceUID: route.outputDeviceUID)
        }
        // Drop routes no longer in config (unless a knob still controls volume).
        let volumeApps = Set(config.knobs.compactMap { $0.appVolumeBundleID })
        for id in tapRouter.routedBundleIDs where !wanted.contains(id) && !volumeApps.contains(id) {
            tapRouter.clearRoute(bundleID: id)
        }
    }

    // MARK: - Event entry points

    func handle(event: DeviceEvent) {
        switch event {
        case .knobChanged(let idx, _, let pct):
            handleKnob(idx: idx, percent: pct)
        case .buttonPressed(let idx):
            handleButtonPressed(idx: idx)
        case .buttonReleased(let idx):
            handleButtonReleased(idx: idx)
        case .knobBatch(let pcts):
            for (i, p) in pcts.enumerated() { handleKnob(idx: i, percent: p) }
        case .health, .deviceId:
            break
        }
    }

    // MARK: - Button press lifecycle (short tap vs long hold)

    /// One per index, tracks whether the long-press fired before release.
    private final class PressTracker {
        var longFired: Bool = false
        var task: Task<Void, Never>?
    }
    private var pressTrackers: [Int: PressTracker] = [:]
    /// How long the user must hold a button before the long action fires.
    private let longPressDelay: Duration = .milliseconds(450)

    private func handleButtonPressed(idx: Int) {
        guard idx < config.buttons.count else { return }
        let longBinding = config.buttonsLong[safe: idx] ?? .none

        // If no long-press configured, fire the short action immediately —
        // preserves the prior tap-fires-on-press behavior so users who don't
        // use long-press don't perceive any latency.
        guard longBinding != .none else {
            handleButton(idx: idx)
            return
        }

        let tracker = PressTracker()
        let delay = longPressDelay
        tracker.task = Task { @MainActor [weak self, weak tracker] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let tracker = tracker else { return }
            tracker.longFired = true
            self.fire(binding: longBinding)
            self.log.info("button \(idx) long-press fired")
            DiagSink.shared.info("Actions", "button \(idx) long-press: \(longBinding.displayName)")
        }
        pressTrackers[idx] = tracker
    }

    private func handleButtonReleased(idx: Int) {
        guard let tracker = pressTrackers.removeValue(forKey: idx) else { return }
        tracker.task?.cancel()
        if !tracker.longFired {
            handleButton(idx: idx)
        }
    }

    private func handleKnob(idx: Int, percent: Double) {
        guard idx < config.knobs.count else { return }
        let binding = config.knobs[idx]
        // Surface the HUD for everything except `.none`, so the user sees a
        // floating pill with what's being controlled and the current value.
        if binding != .none {
            KnobHUD.shared.show(
                label: hudLabel(for: binding),
                value: percent,
                icon: hudIcon(for: binding)
            )
        }
        switch binding {
        case .none:
            return
        case .masterVolume:
            let value = Float(percent / 100.0)
            let ok = CoreAudioVolume.setMasterVolume(value)
            log.info("knob \(idx) → master vol \(percent, privacy: .public)%  coreaudio=\(ok ? "ok" : "FAIL", privacy: .public)")
            if !ok {
                OSAVolume.setOutputVolume(Int(percent.rounded()))
            }
        case .micVolume:
            let value = Float(percent / 100.0)
            if !CoreAudioVolume.setMicVolume(value) {
                OSAVolume.setInputVolume(Int(percent.rounded()))
            }
        case .brightness:
            Brightness.setBuiltInBrightness(Float(percent / 100.0))
        case .lightBrightness:
            ledBrightness = percent / 100.0
        case .spotifyVolume:
            AppleScriptApps.setSpotifyVolume(Int(percent.rounded()))
        case .musicAppVolume:
            AppleScriptApps.setMusicVolume(Int(percent.rounded()))
        case .appVolume(let bundleID):
            guard !bundleID.isEmpty else { return }
            tapRouter.setVolume(bundleID: bundleID, gain: Float(percent / 100.0))
        }
    }

    private func handleButton(idx: Int) {
        guard idx < config.buttons.count else { return }
        fire(binding: config.buttons[idx])
    }

    /// Execute a single button action. Shared between short-tap and long-hold
    /// dispatch paths so adding new actions only needs one switch update.
    private func fire(binding: ButtonBinding) {
        switch binding {
        case .none:
            return
        case .playPause:
            MediaKeys.tap(MediaKeys.playPause)
        case .nextTrack:
            MediaKeys.tap(MediaKeys.next)
        case .previousTrack:
            MediaKeys.tap(MediaKeys.previous)
        case .muteSystem:
            systemMuted.toggle()
            _ = CoreAudioVolume.setMasterMute(systemMuted)
        case .muteMic:
            micMuted.toggle()
            _ = CoreAudioVolume.setMicMute(micMuted)
        case .spotifyPlayPause:
            AppleScriptApps.spotifyPlayPause()
        case .spotifyShuffleToggle:
            AppleScriptApps.spotifyShuffleToggle()
        case .spotifyRepeatToggle:
            AppleScriptApps.spotifyRepeatToggle()
        case .cycleOutputDevices:
            log.info("cycleOutputDevices: not yet implemented")
        case .launchApp(let bundleId):
            launchApp(bundleId: bundleId)
        case .shellCommand(let command):
            runShellCommand(command)
        }
    }

    private func runShellCommand(_ command: String) {
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-lc", command]
        do {
            try p.run()
            DiagSink.shared.info("Actions", "shell: \(command.prefix(60))")
        } catch {
            log.error("shell command failed: \(error.localizedDescription, privacy: .public)")
            DiagSink.shared.error("Actions", "shell failed: \(error.localizedDescription)")
        }
    }

    // MARK: - HUD labels

    private func hudLabel(for binding: KnobBinding) -> String {
        switch binding {
        case .none:             return "—"
        case .masterVolume:     return "Master volume"
        case .micVolume:        return "Microphone"
        case .brightness:       return "Display brightness"
        case .lightBrightness:  return "LED brightness"
        case .spotifyVolume:    return "Spotify"
        case .musicAppVolume:   return "Music"
        case .appVolume(let b): return b.isEmpty ? "App volume" : AppNames.short(b)
        }
    }

    private func hudIcon(for binding: KnobBinding) -> String {
        switch binding {
        case .none:             return "minus.circle"
        case .masterVolume:     return "speaker.wave.3.fill"
        case .micVolume:        return "mic.fill"
        case .brightness:       return "sun.max.fill"
        case .lightBrightness:  return "lightspectrum.horizontal"
        case .spotifyVolume:    return "music.note"
        case .musicAppVolume:   return "music.note.list"
        case .appVolume:        return "app.fill"
        }
    }

    private func launchApp(bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
