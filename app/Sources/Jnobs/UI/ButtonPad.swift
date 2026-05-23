import SwiftUI

/// A small flat "pad" that flashes mint when the corresponding hardware button
/// is pressed. Read-only; the device drives the press state.
struct ButtonPad: View {
    var index: Int
    var label: String? = nil
    /// True for ~120 ms when the underlying physical button is pressed.
    var pressed: Bool = false
    var size: CGFloat = 44

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(RadialGradient(
                        colors: pressed
                            ? [Jn.mintGlow, Jn.mint, Jn.mintDim]
                            : [Jn.cardHi, Jn.card, Jn.panelDeep],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.7
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(pressed ? Jn.mintGlow : Jn.strokeHi, lineWidth: 0.5)
                    )
                    .shadow(color: pressed ? Jn.mint.opacity(0.7) : .clear,
                            radius: size * 0.25)
                Text("\(index + 1)")
                    .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                    .foregroundStyle(pressed ? .black.opacity(0.85) : Jn.inkMute)
            }
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.12), value: pressed)
            if let label {
                Text(label)
                    .font(.system(size: max(9, size * 0.21), weight: .medium, design: .rounded))
                    .foregroundStyle(Jn.inkMute)
                    .lineLimit(1)
            }
        }
    }
}
