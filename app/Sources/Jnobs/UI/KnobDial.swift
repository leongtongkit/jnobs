import SwiftUI

/// A studio-style rotary dial that mirrors the physical knob's position and the
/// device's 3-LED "fan" above it. Read-only — the source of truth is the hardware.
struct KnobDial: View {
    /// 0...100 — current knob position.
    var percent: Double
    /// The current colors of the 3 hardware LEDs (left, middle, right) above this knob.
    var ledColors: [Color] = [Jn.mintDim, Jn.mintDim, Jn.mintDim]
    /// Optional label drawn below the dial.
    var label: String? = nil
    /// Optional sublabel — usually the live value (e.g. "62%").
    var sublabel: String? = nil
    /// Dial diameter in points.
    var size: CGFloat = 72
    /// Whether the dial should appear "alive" — pulses/animates differently when offline.
    var isLive: Bool = true

    private var sweepStart: Angle { .degrees(135) }   // 7 o'clock
    private var sweepEnd:   Angle { .degrees(45) }    // 5 o'clock (going clockwise)
    private var sweepDeg: Double { 270 }

    private var indicatorAngle: Angle {
        // Convert percent → angle along the 270° sweep.
        let p = max(0, min(1, percent / 100.0))
        return .degrees(135 + sweepDeg * p)
    }

    var body: some View {
        VStack(spacing: 6) {
            ledFan
            ZStack {
                trackArc
                activeArc
                dialBody
                indicator
            }
            .frame(width: size, height: size)
            if label != nil || sublabel != nil {
                VStack(spacing: 1) {
                    if let label {
                        Text(label)
                            .font(.system(size: max(10, size * 0.13), weight: .semibold, design: .rounded))
                            .foregroundStyle(Jn.ink)
                            .lineLimit(1)
                    }
                    if let sublabel {
                        Text(sublabel)
                            .font(.system(size: max(9, size * 0.115), weight: .medium, design: .monospaced))
                            .foregroundStyle(Jn.inkMute)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private var ledFan: some View {
        HStack(spacing: size * 0.085) {
            ForEach(0..<3, id: \.self) { i in
                let c = ledColors[safeIdx: i] ?? Jn.mintDim
                Circle()
                    .fill(c)
                    .frame(width: size * 0.085, height: size * 0.085)
                    .shadow(color: c.opacity(isLive ? 0.85 : 0.0), radius: size * 0.07, x: 0, y: 0)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            }
        }
        .frame(height: size * 0.14)
    }

    private var trackArc: some View {
        Circle()
            .trim(from: 0, to: CGFloat(sweepDeg / 360.0))
            .stroke(Jn.stroke, style: StrokeStyle(lineWidth: max(2, size * 0.05), lineCap: .round))
            .rotationEffect(.degrees(135))    // SwiftUI Circle.trim starts at 3 o'clock; +135° → 7:30 (matches indicator at p=0)
            .frame(width: size * 0.92, height: size * 0.92)
    }

    private var activeArc: some View {
        let p = max(0, min(1, percent / 100.0))
        return Circle()
            .trim(from: 0, to: CGFloat(p * (sweepDeg / 360.0)))
            .stroke(
                AngularGradient(
                    colors: [Jn.mint, Jn.mintGlow],
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360)
                ),
                style: StrokeStyle(lineWidth: max(2, size * 0.05), lineCap: .round)
            )
            .rotationEffect(.degrees(135))
            .frame(width: size * 0.92, height: size * 0.92)
            .shadow(color: Jn.mint.opacity(isLive && p > 0.02 ? 0.55 : 0), radius: size * 0.08)
            .animation(.easeOut(duration: 0.08), value: percent)
    }

    private var dialBody: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Jn.cardHi, Jn.card, Jn.panelDeep],
                    center: UnitPoint(x: 0.32, y: 0.30),
                    startRadius: 0,
                    endRadius: size * 0.5
                ))
                .frame(width: size * 0.72, height: size * 0.72)
                .overlay(
                    Circle()
                        .stroke(Jn.strokeHi, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: size * 0.03, x: 0, y: size * 0.015)
            // Inner cap highlight ring.
            Circle()
                .stroke(Color.white.opacity(0.05), lineWidth: max(0.5, size * 0.012))
                .frame(width: size * 0.58, height: size * 0.58)
        }
    }

    private var indicator: some View {
        // A short mint stroke from inner radius to outer edge of the dial cap,
        // rotated to the current indicator angle.
        let radiusInner = size * 0.18
        let radiusOuter = size * 0.34
        return GeometryReader { geo in
            let c = CGPoint(x: geo.size.width/2, y: geo.size.height/2)
            // angle in SwiftUI rotation: 0 = up, increases clockwise
            // we want indicatorAngle.degrees (135..405) where 135=down-left
            let theta = indicatorAngle.radians
            // Convert from "trim start at 3 o'clock, rotated -90°" coordinate.
            // Easier: compute end points directly in standard math coords (0=right, ccw),
            // but SwiftUI uses 0=down, cw — so map.
            // We'll just compute the screen-space line using cos/sin with a manual offset:
            // Our percent-to-angle maps p=0 → 7 o'clock, p=1 → 5 o'clock via degrees(135..405).
            // In screen coords (y down, 0° at +x): 7 o'clock = 135° (lower-left). Match.
            let p0 = CGPoint(x: c.x + cos(theta) * radiusInner,
                             y: c.y + sin(theta) * radiusInner)
            let p1 = CGPoint(x: c.x + cos(theta) * radiusOuter,
                             y: c.y + sin(theta) * radiusOuter)
            Path { p in p.move(to: p0); p.addLine(to: p1) }
                .stroke(Jn.mint, style: StrokeStyle(lineWidth: max(1.5, size * 0.05), lineCap: .round))
                .shadow(color: Jn.mint.opacity(isLive ? 0.85 : 0), radius: size * 0.06)
                .animation(.easeOut(duration: 0.08), value: percent)
        }
        .allowsHitTesting(false)
    }
}

extension Array {
    fileprivate subscript(safeIdx i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
