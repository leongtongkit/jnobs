import Foundation

// NOTE: Phase B (per-app volume + output routing via Core Audio process taps)
// validated 2026-05-23 — see FEASIBILITY_per_app_audio.md and probe/tap_probe.swift.
// Tap format: 48kHz/2ch/float/interleaved. TapRouter engine is next.

/// Persistent configuration: per-knob and per-button actions, plus LED colors.
///
/// Stored at `~/Library/Application Support/Jnobs/config.json`. Defaults:
/// knob 0 = master volume, buttons 0-2 = media controls, all lights mint
/// position-fill. See `AppConfig.default` for the full set.
/// A snapshot of the four binding layers (knobs / buttons short / buttons long
/// / lights) plus a name. The user can save the current Console state as a
/// profile and load it back later to switch contexts (gaming / music / work)
/// without rebinding everything manually.
///
/// Stored alongside the live config; the live config remains the source of
/// truth for what the device is currently doing — loading a profile copies
/// its bindings into the live fields.
struct Profile: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var knobs: [KnobBinding]
    var buttons: [ButtonBinding]
    var buttonsLong: [ButtonBinding]
    var lights: [LightBinding]
    /// Per-app output routes — saved per profile so a "Gaming" profile can
    /// route headset audio to AirPods while "Work" routes the same apps to
    /// monitor speakers, switched in one click.
    var appRoutes: [AppRoute]
    /// Captured along with bindings — auto-mute mic on silence is per-context
    /// (you usually want it on during calls, off when streaming).
    var autoMuteMic: Bool
    var id: String { name }

    /// Backward-compatible decode: routes + autoMuteMic optional in older profile JSONs.
    init(name: String, knobs: [KnobBinding], buttons: [ButtonBinding],
         buttonsLong: [ButtonBinding], lights: [LightBinding],
         appRoutes: [AppRoute] = [], autoMuteMic: Bool = false) {
        self.name = name
        self.knobs = knobs
        self.buttons = buttons
        self.buttonsLong = buttonsLong
        self.lights = lights
        self.appRoutes = appRoutes
        self.autoMuteMic = autoMuteMic
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        knobs = try c.decode([KnobBinding].self, forKey: .knobs)
        buttons = try c.decode([ButtonBinding].self, forKey: .buttons)
        buttonsLong = (try? c.decode([ButtonBinding].self, forKey: .buttonsLong))
            ?? Array(repeating: .none, count: buttons.count)
        lights = try c.decode([LightBinding].self, forKey: .lights)
        appRoutes = (try? c.decode([AppRoute].self, forKey: .appRoutes)) ?? []
        autoMuteMic = (try? c.decode(Bool.self, forKey: .autoMuteMic)) ?? false
    }
}

struct AppConfig: Codable, Sendable, Equatable {
    var knobs: [KnobBinding]
    var buttons: [ButtonBinding]
    /// Optional secondary action per button, triggered by holding the button
    /// for ~450 ms instead of tapping. Same length as `buttons`. `.none`
    /// disables long-press for that button (the short action fires
    /// immediately on press, preserving the prior behavior).
    var buttonsLong: [ButtonBinding]
    var lights: [LightBinding]
    /// Per-app output routing: send an app's audio to a specific device.
    var appRoutes: [AppRoute]
    /// When true, the input device is auto-muted on silence and unmuted on
    /// detected speech (energy threshold + hysteresis).
    var autoMuteMic: Bool
    /// Saved snapshots of binding layers, keyed by user-chosen name.
    var profiles: [Profile]
    /// Name of the most recently loaded profile (informational; the live
    /// fields above are the source of truth).
    var activeProfileName: String?

    static let `default` = AppConfig(
        knobs: [
            .masterVolume,
            .micVolume,
            .spotifyVolume,
            .musicAppVolume,
            .brightness
        ],
        buttons: [
            .previousTrack,
            .playPause,
            .nextTrack,
            .muteSystem,
            .muteMic
        ],
        buttonsLong: Array(repeating: .none, count: 5),
        lights: Array(repeating: .positionFill(color: .mint), count: 5),
        appRoutes: [],
        autoMuteMic: false,
        profiles: [],
        activeProfileName: nil
    )

    // Backward-compatible decode: optional fields default-fill when missing.
    init(knobs: [KnobBinding], buttons: [ButtonBinding],
         buttonsLong: [ButtonBinding] = [], lights: [LightBinding],
         appRoutes: [AppRoute] = [], autoMuteMic: Bool = false,
         profiles: [Profile] = [], activeProfileName: String? = nil) {
        self.knobs = knobs
        self.buttons = buttons
        self.buttonsLong = buttonsLong.isEmpty ? Array(repeating: .none, count: buttons.count) : buttonsLong
        self.lights = lights
        self.appRoutes = appRoutes
        self.autoMuteMic = autoMuteMic
        self.profiles = profiles
        self.activeProfileName = activeProfileName
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        knobs = try c.decode([KnobBinding].self, forKey: .knobs)
        buttons = try c.decode([ButtonBinding].self, forKey: .buttons)
        lights = try c.decode([LightBinding].self, forKey: .lights)
        appRoutes = (try? c.decode([AppRoute].self, forKey: .appRoutes)) ?? []
        let long = (try? c.decode([ButtonBinding].self, forKey: .buttonsLong)) ?? []
        buttonsLong = long.count == buttons.count
            ? long
            : Array(repeating: .none, count: buttons.count)
        autoMuteMic = (try? c.decode(Bool.self, forKey: .autoMuteMic)) ?? false
        profiles = (try? c.decode([Profile].self, forKey: .profiles)) ?? []
        activeProfileName = try? c.decode(String.self, forKey: .activeProfileName)
    }
}

extension AppConfig {
    /// Capture the entire user-settable surface (bindings, routes, mic
    /// auto-mute) as a new profile. Overwrites if a profile by that name
    /// already exists. Anything *not* in the Profile struct (e.g. transient
    /// device state) is shared across profiles.
    mutating func saveProfile(named name: String) {
        let p = Profile(
            name: name,
            knobs: knobs,
            buttons: buttons,
            buttonsLong: buttonsLong,
            lights: lights,
            appRoutes: appRoutes,
            autoMuteMic: autoMuteMic
        )
        if let i = profiles.firstIndex(where: { $0.name == name }) {
            profiles[i] = p
        } else {
            profiles.append(p)
        }
        activeProfileName = name
    }

    /// Replace the live state from the named profile. No-op if not found.
    mutating func loadProfile(named name: String) {
        guard let p = profiles.first(where: { $0.name == name }) else { return }
        knobs = p.knobs
        buttons = p.buttons
        buttonsLong = p.buttonsLong.count == p.buttons.count
            ? p.buttonsLong
            : Array(repeating: .none, count: p.buttons.count)
        lights = p.lights
        appRoutes = p.appRoutes
        autoMuteMic = p.autoMuteMic
        activeProfileName = p.name
    }

    mutating func deleteProfile(named name: String) {
        profiles.removeAll { $0.name == name }
        if activeProfileName == name { activeProfileName = nil }
    }
}

/// Routes one app's audio to a chosen output device (nil = system default).
struct AppRoute: Codable, Sendable, Equatable, Identifiable {
    var bundleID: String
    var outputDeviceUID: String?
    var id: String { bundleID }
}

/// What a knob should control. Matches the original's KnobConfigurations.
enum KnobBinding: Codable, Sendable, Equatable, Hashable {
    case none
    case masterVolume
    case micVolume
    case brightness            // built-in display brightness
    case lightBrightness       // device LED max-intensity multiplier
    case spotifyVolume
    case musicAppVolume
    case appVolume(bundleID: String)   // per-app volume via TapRouter
}

/// What a button should do. Matches the original's ButtonConfigurations.
enum ButtonBinding: Codable, Sendable, Equatable, Hashable, CaseIterable {
    case none
    case playPause
    case nextTrack
    case previousTrack
    case muteSystem
    case muteMic
    case spotifyPlayPause
    case spotifyShuffleToggle
    case spotifyRepeatToggle
    case cycleOutputDevices
    case launchApp(bundleId: String)
    /// Run an arbitrary shell command via `/bin/zsh -lc`. Power-user escape
    /// hatch. Output is discarded. Errors are logged to DiagSink.
    case shellCommand(command: String)
}

extension ButtonBinding {
    static var allCases: [ButtonBinding] {
        [.none, .playPause, .nextTrack, .previousTrack, .muteSystem,
         .muteMic, .spotifyPlayPause, .spotifyShuffleToggle,
         .spotifyRepeatToggle, .cycleOutputDevices]
    }
}

/// What a knob's LED fan should display. Matches the original's LightConfigurations.
enum LightBinding: Codable, Sendable, Equatable {
    case off
    case singleColor(color: RGB)
    case positionFill(color: RGB)        // LED segments fill in proportion to knob value
    case positionBlend(low: RGB, high: RGB)
    case microphoneStatus(active: RGB, muted: RGB)
    case rainbow
}

// MARK: - Persistence

enum ConfigStore {
    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Jnobs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return .default }
        return cfg
    }

    static func save(_ cfg: AppConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
