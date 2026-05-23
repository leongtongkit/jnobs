import SwiftUI
import AppKit

/// A short-lived floating pill that appears bottom-center when a knob moves,
/// showing what it controls and its current value — like macOS's volume HUD
/// but driven by our hardware. Auto-hides ~900 ms after the last update.
@MainActor
final class KnobHUD: ObservableObject {
    static let shared = KnobHUD()

    @Published private(set) var label: String = ""
    @Published private(set) var value: Double = 0
    @Published private(set) var icon: String = "dial.medium.fill"
    @Published private(set) var showing: Bool = false

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let hideAfter: Duration = .milliseconds(900)

    private init() {}

    /// Show or update the HUD with a fresh label/value. Restarts the auto-hide timer.
    func show(label: String, value: Double, icon: String = "dial.medium.fill") {
        self.label = label
        self.value = max(0, min(100, value))
        self.icon = icon
        ensurePanel()
        if !showing {
            showing = true
            panel?.alphaValue = 0
            panel?.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel?.animator().alphaValue = 1
            }
        }
        hideTask?.cancel()
        let delay = hideAfter
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard showing else { return }
        guard let panel else { showing = false; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.showing = false
        })
    }

    private func ensurePanel() {
        if panel != nil {
            reposition()
            return
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        // Disable the system's rectangular shadow — it follows the panel's
        // square bounds, not the SwiftUI rounded-rect inside, which is what
        // shows up as a black box around the pill. SwiftUI's own .shadow()
        // on the RoundedRectangle background draws the correct rounded shadow.
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: KnobHUDView(hud: self))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 110)
        // Make the host view itself transparent so the SwiftUI rounded-rect
        // corners don't reveal a black/opaque NSHostingView layer behind them.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        p.contentView = hosting

        panel = p
        reposition()
    }

    private func reposition() {
        guard let panel,
              let screen = NSScreen.main else { return }
        let s = panel.frame.size
        let x = screen.frame.midX - s.width / 2
        let y = screen.visibleFrame.minY + 110
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - View

private struct KnobHUDView: View {
    @ObservedObject var hud: KnobHUD

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: hud.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Jn.mint)
                .shadow(color: Jn.mint.opacity(0.45), radius: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(hud.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Jn.ink)
                    .lineLimit(1)
                meter
                Text("\(Int(hud.value.rounded()))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Jn.inkMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Jn.panelDeep.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Jn.strokeHi, lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 6)
        )
        // Margin so the SwiftUI shadow has room to render without being
        // clipped by the panel edges.
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .environment(\.colorScheme, .dark)
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Jn.cardHi.opacity(0.55))
                    .overlay(Capsule().stroke(Jn.stroke, lineWidth: 0.5))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Jn.mintDim, Jn.mint, Jn.mintGlow],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(2, geo.size.width * hud.value / 100.0))
                    .shadow(color: Jn.mint.opacity(0.6), radius: 3)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.10), value: hud.value)
    }
}
