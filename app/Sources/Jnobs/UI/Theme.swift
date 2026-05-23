import SwiftUI

/// Jnobs visual identity — mint accent on charcoal studio-panel surfaces.
enum Jn {
    // Brand colors.
    static let mint      = Color(red: 0/255,   green: 220/255, blue: 90/255)
    static let mintGlow  = Color(red: 64/255,  green: 240/255, blue: 140/255)
    static let mintDim   = Color(red: 0/255,   green: 110/255, blue: 55/255)

    // Surface colors. Tuned for dark mode (which is the only mode this app
    // ships — a menu-bar studio tool, not a system-level UI).
    static let panel      = Color(red:  22/255, green:  24/255, blue:  28/255)
    static let panelDeep  = Color(red:  14/255, green:  16/255, blue:  20/255)
    static let card       = Color(red:  30/255, green:  33/255, blue:  38/255)
    static let cardHi     = Color(red:  42/255, green:  46/255, blue:  52/255)
    static let stroke     = Color.white.opacity(0.06)
    static let strokeHi   = Color.white.opacity(0.12)

    // Text.
    static let ink        = Color.white.opacity(0.92)
    static let inkMute    = Color.white.opacity(0.55)
    static let inkFaint   = Color.white.opacity(0.32)
}

// MARK: - Wordmark

/// The "Jnobs" wordmark — J in mint, rest in ink. Set in Lacquer (display)
/// for a hand-painted studio-panel character. Used in the Console header and
/// the menu-bar popover. Lacquer ships single-weight, so the visual emphasis
/// comes from color + size rather than weight contrast.
struct Wordmark: View {
    var size: CGFloat = 22

    /// Lacquer renders ~15% smaller than the rounded system face at the same
    /// nominal point size, so we scale up to keep the wordmark's footprint
    /// consistent with the rest of the UI.
    private var renderSize: CGFloat { size * 1.2 }

    var body: some View {
        HStack(spacing: 0) {
            Text("J")
                .font(.custom("Lacquer-Regular", size: renderSize))
                .foregroundStyle(Jn.mint)
                .shadow(color: Jn.mint.opacity(0.45), radius: renderSize * 0.18, x: 0, y: 0)
            Text("nobs")
                .font(.custom("Lacquer-Regular", size: renderSize))
                .foregroundStyle(Jn.ink)
                .tracking(0.5)
        }
    }
}

// MARK: - Surface modifiers

extension View {
    /// A studio-panel "card" surface: subtle gradient fill, hairline stroke,
    /// soft inset shadow. Use for grouping inside the Console window.
    func jnCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Jn.cardHi.opacity(0.65), Jn.card],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Jn.stroke, lineWidth: 1)
                    )
            )
    }

    /// The outer panel surface — used as the window/popover background.
    func jnPanelBackground() -> some View {
        self.background(
            LinearGradient(
                colors: [Jn.panel, Jn.panelDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}

// MARK: - Section header

/// Small mono-weight caption with a left mint marker. Sits above a card.
struct SectionCaption: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Jn.mint)
                .frame(width: 2, height: 11)
                .clipShape(Capsule())
            if let s = symbol {
                Image(systemName: s)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Jn.inkMute)
            }
            Text(text.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(Jn.inkMute)
        }
    }
}

// MARK: - Status pill

/// "Connected · cu.usbmodem001" — pulse dot when live, gray when not.
struct StatusPill: View {
    let connected: Bool
    let text: String

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(connected ? Jn.mint : Jn.inkFaint)
                    .frame(width: 7, height: 7)
                if connected {
                    Circle()
                        .stroke(Jn.mint.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulse ? 2.4 : 1.0)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false),
                                   value: pulse)
                }
            }
            .frame(width: 14, height: 14)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(connected ? Jn.ink : Jn.inkMute)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Jn.cardHi.opacity(0.7))
                .overlay(Capsule().stroke(Jn.stroke, lineWidth: 1))
        )
        .onAppear { if connected { pulse = true } }
        .onChange(of: connected) { _, c in pulse = c }
    }
}

// MARK: - RGB → Color bridge

extension RGB {
    var swiftColor: Color {
        Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
    }
}
