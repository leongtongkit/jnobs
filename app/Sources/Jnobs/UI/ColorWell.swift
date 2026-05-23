import SwiftUI
import AppKit

/// Inline color well that opens a popover anchored to its swatch — replacing
/// SwiftUI's `ColorPicker`, which delegates to the shared system `NSColorPanel`
/// (floats wherever it was last left, can't be anchored to a view).
///
/// Drops the alpha slider entirely (LEDs are opaque) and exposes a curated
/// palette + HSV sliders. The preview row shows the picked color next to the
/// gamma-corrected color the hardware will actually emit, so mid-tone crush
/// from the perceptual gamma LUT isn't a surprise.
struct JnColorWell: View {
    @Binding var rgb: RGB
    var size: CGFloat = 26

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rgb.swiftColor)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Jn.strokeHi, lineWidth: 1)
            }
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .leading) {
            JnColorPickerSheet(rgb: $rgb)
                .frame(width: 240)
                .padding(12)
                .background(Jn.panel)
        }
    }
}

// MARK: - Sheet

private struct JnColorPickerSheet: View {
    @Binding var rgb: RGB

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var syncing = false   // suppress slider→rgb during onAppear

    private static let presets: [(name: String, rgb: RGB)] = [
        ("Off",     .off),
        ("White",   .white),
        ("Mint",    .mint),
        ("Red",     RGB(r: 255, g: 0,   b: 0)),
        ("Orange",  RGB(r: 255, g: 110, b: 0)),
        ("Amber",   RGB(r: 255, g: 200, b: 0)),
        ("Lime",    RGB(r: 110, g: 255, b: 0)),
        ("Green",   RGB(r: 0,   g: 255, b: 0)),
        ("Teal",    RGB(r: 0,   g: 200, b: 180)),
        ("Cyan",    RGB(r: 0,   g: 200, b: 255)),
        ("Blue",    RGB(r: 0,   g: 60,  b: 255)),
        ("Purple",  RGB(r: 150, g: 0,   b: 255)),
        ("Magenta", RGB(r: 255, g: 0,   b: 200)),
        ("Pink",    RGB(r: 255, g: 110, b: 180)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCaption(text: "Preset")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Self.presets, id: \.name) { p in
                    Button {
                        rgb = p.rgb
                        syncSlidersFromRGB()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(p.rgb.swiftColor)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(rgb == p.rgb ? Jn.mint : Jn.stroke,
                                        lineWidth: rgb == p.rgb ? 1.5 : 1)
                        }
                        .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(p.name)
                }
            }

            SectionCaption(text: "Custom")
            VStack(spacing: 6) {
                HSlider(label: "H", value: $hue, gradient: hueGradient)
                HSlider(label: "S", value: $saturation, gradient: satGradient)
                HSlider(label: "V", value: $brightness, gradient: brightnessGradient)
            }
            .onChange(of: hue)        { _, _ in if !syncing { rgb = Self.hsvToRGB(h: hue, s: saturation, v: brightness) } }
            .onChange(of: saturation) { _, _ in if !syncing { rgb = Self.hsvToRGB(h: hue, s: saturation, v: brightness) } }
            .onChange(of: brightness) { _, _ in if !syncing { rgb = Self.hsvToRGB(h: hue, s: saturation, v: brightness) } }

            SectionCaption(text: "Preview")
            HStack(spacing: 10) {
                previewSwatch(label: "Picked",  color: rgb.swiftColor)
                previewSwatch(label: "On LED",  color: rgb.gammaCorrected().swiftColor)
            }
        }
        .onAppear { syncSlidersFromRGB() }
    }

    private func previewSwatch(label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Jn.strokeHi))
                .frame(height: 28)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Jn.inkMute)
        }
    }

    private var hueGradient: LinearGradient {
        let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
            Color(hue: $0, saturation: 1, brightness: 1)
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }

    private var satGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hue: hue, saturation: 0, brightness: brightness),
                     Color(hue: hue, saturation: 1, brightness: brightness)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var brightnessGradient: LinearGradient {
        LinearGradient(
            colors: [.black, Color(hue: hue, saturation: saturation, brightness: 1)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func syncSlidersFromRGB() {
        syncing = true
        let (h, s, v) = Self.rgbToHSV(rgb)
        hue = h; saturation = s; brightness = v
        DispatchQueue.main.async { syncing = false }
    }

    // MARK: Manual HSV ↔ sRGB (avoids NSColor's calibrated-vs-sRGB footguns)

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> RGB {
        let hh = max(0, min(1, h)) * 6
        let i = Int(floor(hh)) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default:(r, g, b) = (v, p, q)
        }
        return RGB(
            r: UInt8(max(0, min(255, (r * 255).rounded()))),
            g: UInt8(max(0, min(255, (g * 255).rounded()))),
            b: UInt8(max(0, min(255, (b * 255).rounded())))
        )
    }

    private static func rgbToHSV(_ c: RGB) -> (h: Double, s: Double, v: Double) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 0 {
            switch mx {
            case r: h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
            case g: h = (b - r) / d + 2
            default:h = (r - g) / d + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = mx == 0 ? 0 : d / mx
        return (h, s, mx)
    }
}

// MARK: - Slider

private struct HSlider: View {
    let label: String
    @Binding var value: Double
    let gradient: LinearGradient

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Jn.inkMute)
                .frame(width: 12, alignment: .leading)

            GeometryReader { geo in
                let knob = 14.0
                let trackW = geo.size.width
                let usable = max(1, trackW - knob)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(gradient)
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Jn.stroke, lineWidth: 0.5)
                        .frame(height: 12)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                        .frame(width: knob, height: knob)
                        .offset(x: value * usable)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let x = g.location.x - knob / 2
                    value = max(0, min(1, x / usable))
                })
            }
            .frame(height: 16)

            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Jn.inkMute)
                .frame(width: 26, alignment: .trailing)
        }
    }
}
