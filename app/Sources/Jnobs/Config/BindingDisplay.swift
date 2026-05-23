import Foundation
import SwiftUI

// Display metadata + picker plumbing for the binding enums, so the settings UI
// can present friendly names and edit them without leaking enum internals.

extension KnobBinding: Identifiable {
    var id: String {
        if case .appVolume(let b) = self { return "appVolume:\(b)" }
        return displayName
    }

    var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .masterVolume: return "Master volume"
        case .micVolume: return "Microphone volume"
        case .brightness: return "Display brightness"
        case .lightBrightness: return "LED brightness"
        case .spotifyVolume: return "Spotify volume"
        case .musicAppVolume: return "Music volume"
        case .appVolume(let b): return b.isEmpty ? "App volume…" : "App: \(AppNames.short(b))"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "minus.circle"
        case .masterVolume: return "speaker.wave.3.fill"
        case .micVolume: return "mic.fill"
        case .brightness: return "sun.max.fill"
        case .lightBrightness: return "lightbulb.fill"
        case .spotifyVolume: return "music.note"
        case .musicAppVolume: return "music.note.list"
        case .appVolume: return "app.badge.fill"
        }
    }

    /// Cases offered in the picker. `appVolume` appears as a placeholder that
    /// reveals an app chooser in the row.
    static var pickable: [KnobBinding] {
        [.none, .masterVolume, .micVolume, .brightness, .lightBrightness,
         .spotifyVolume, .musicAppVolume, .appVolume(bundleID: "")]
    }

    var isAppVolume: Bool {
        if case .appVolume = self { return true }; return false
    }

    var appVolumeBundleID: String? {
        if case .appVolume(let b) = self { return b }; return nil
    }
}

/// Friendly names for bundle IDs.
enum AppNames {
    static func short(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName {
            return name
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

extension ButtonBinding: Identifiable {
    var id: String { displayName }

    var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .muteSystem: return "Mute system"
        case .muteMic: return "Mute microphone"
        case .spotifyPlayPause: return "Spotify play/pause"
        case .spotifyShuffleToggle: return "Spotify shuffle"
        case .spotifyRepeatToggle: return "Spotify repeat"
        case .cycleOutputDevices: return "Cycle output device"
        case .launchApp: return "Launch app…"
        case .shellCommand: return "Shell command…"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "minus.circle"
        case .playPause: return "playpause.fill"
        case .nextTrack: return "forward.fill"
        case .previousTrack: return "backward.fill"
        case .muteSystem: return "speaker.slash.fill"
        case .muteMic: return "mic.slash.fill"
        case .spotifyPlayPause: return "music.note"
        case .spotifyShuffleToggle: return "shuffle"
        case .spotifyRepeatToggle: return "repeat"
        case .cycleOutputDevices: return "rectangle.2.swap"
        case .launchApp: return "app.badge"
        case .shellCommand: return "terminal"
        }
    }

    static var pickable: [ButtonBinding] {
        [.none, .playPause, .nextTrack, .previousTrack, .muteSystem,
         .muteMic, .spotifyPlayPause, .spotifyShuffleToggle,
         .spotifyRepeatToggle, .cycleOutputDevices]
    }
}

/// Discriminator for LightBinding, used to drive the effect picker.
enum LightKind: String, CaseIterable, Identifiable {
    case off, single, positionFill, positionBlend, micStatus, rainbow
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .single: return "Solid color"
        case .positionFill: return "Volume fill"
        case .positionBlend: return "Color blend"
        case .micStatus: return "Mic status"
        case .rainbow: return "Rainbow"
        }
    }
}

extension LightBinding {
    var kind: LightKind {
        switch self {
        case .off: return .off
        case .singleColor: return .single
        case .positionFill: return .positionFill
        case .positionBlend: return .positionBlend
        case .microphoneStatus: return .micStatus
        case .rainbow: return .rainbow
        }
    }

    /// Primary color of the effect (for the color well), if any.
    var primaryColor: RGB {
        switch self {
        case .off: return .off
        case .singleColor(let c): return c
        case .positionFill(let c): return c
        case .positionBlend(let lo, _): return lo
        case .microphoneStatus(let a, _): return a
        case .rainbow: return .mint
        }
    }

    var secondaryColor: RGB {
        switch self {
        case .positionBlend(_, let hi): return hi
        case .microphoneStatus(_, let m): return m
        default: return .red
        }
    }

    /// Build a binding for a given kind, preserving colors where possible.
    static func make(kind: LightKind, primary: RGB, secondary: RGB) -> LightBinding {
        switch kind {
        case .off: return .off
        case .single: return .singleColor(color: primary)
        case .positionFill: return .positionFill(color: primary)
        case .positionBlend: return .positionBlend(low: primary, high: secondary)
        case .micStatus: return .microphoneStatus(active: primary, muted: secondary)
        case .rainbow: return .rainbow
        }
    }

    var usesSecondaryColor: Bool {
        switch kind {
        case .positionBlend, .micStatus: return true
        default: return false
        }
    }

    var usesPrimaryColor: Bool {
        switch kind {
        case .off, .rainbow: return false
        default: return true
        }
    }
}

// MARK: - RGB ⇄ SwiftUI Color

extension RGB {
    var color: Color {
        Color(.sRGB,
              red: Double(r) / 255.0,
              green: Double(g) / 255.0,
              blue: Double(b) / 255.0,
              opacity: 1)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            r: UInt8(max(0, min(1, ns.redComponent)) * 255),
            g: UInt8(max(0, min(1, ns.greenComponent)) * 255),
            b: UInt8(max(0, min(1, ns.blueComponent)) * 255)
        )
    }
}
