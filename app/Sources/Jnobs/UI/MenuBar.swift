import SwiftUI

/// Menubar popover — Jnobs wordmark, live dial strip, status pill, action row.
struct MenuBarContent: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var dm: DeviceManager
    @ObservedObject var renderer: LEDRenderer
    @ObservedObject var tapRouter: TapRouter
    let onQuit: () -> Void
    @Environment(\.openWindow) private var openWindow

    private var config: AppConfig { delegate.config }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Jn.stroke)
            dialStrip
            Divider().overlay(Jn.stroke)
            actionRow
        }
        .frame(width: 360)
        .jnPanelBackground()
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Wordmark(size: 18)
            Spacer()
            StatusPill(connected: connected, text: pillText)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var connected: Bool { if case .connected = dm.state { return true }; return false }

    private var pillText: String {
        switch dm.state {
        case .connected(let p): return URL(fileURLWithPath: p).lastPathComponent
        case .connecting: return "Connecting…"
        case .disconnected: return "Searching"
        case .error: return "Error"
        }
    }

    // MARK: Live dial strip

    private var dialStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<5, id: \.self) { i in
                KnobDial(
                    percent: dm.knobPercents[mbSafe: i] ?? 0,
                    ledColors: ledColors(for: i),
                    label: shortLabel(for: i),
                    sublabel: "\(Int(dm.knobPercents[mbSafe: i] ?? 0))%",
                    size: 54,
                    isLive: connected
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    private func ledColors(for knob: Int) -> [Color] {
        guard knob < renderer.currentSlots.count else {
            return [Jn.mintDim.opacity(0.4), Jn.mintDim.opacity(0.4), Jn.mintDim.opacity(0.4)]
        }
        return renderer.currentSlots[knob].map { rgb -> Color in
            if rgb.r < 4 && rgb.g < 4 && rgb.b < 4 {
                return Color.white.opacity(0.08)
            }
            return rgb.swiftColor
        }
    }

    private func shortLabel(for i: Int) -> String {
        guard i < config.knobs.count else { return "K\(i+1)" }
        switch config.knobs[i] {
        case .masterVolume:      return "Master"
        case .micVolume:         return "Mic"
        case .brightness:        return "Display"
        case .lightBrightness:   return "LEDs"
        case .spotifyVolume:     return "Spotify"
        case .musicAppVolume:    return "Music"
        case .appVolume(let b):  return b.isEmpty ? "App" : AppNames.short(b)
        case .none:              return "–"
        }
    }

    // MARK: Action row

    private var actionRow: some View {
        HStack(spacing: 6) {
            menuButton("Console", system: "slider.horizontal.3") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton("Config", system: "doc.text") {
                NSWorkspace.shared.open(ConfigStore.fileURL)
            }
            Spacer()
            menuButton("Quit", system: "power", role: .destructive, onTap: onQuit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func menuButton(_ title: String, system: String,
                            role: ButtonRole? = nil,
                            onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(role == .destructive ? Color.red.opacity(0.9) : Jn.ink)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Jn.cardHi.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Jn.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

fileprivate extension Array {
    subscript(mbSafe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
