import SwiftUI
import AppKit

/// Status-bar icon — stylized knob outline with a 3-dot LED fan. The knob's
/// indicator now rotates with the system master volume, and the LED fan
/// degrades into "fewer dots filled" when muted, so the icon doubles as a
/// glanceable volume indicator.
///
/// Drawn to an NSImage so `MenuBarExtra` renders it reliably as a template
/// (the OS auto-tints it for current menubar state).
struct MenuBarIcon: View {
    var state: DeviceManager.State
    var volume: Float    // 0...1
    var muted: Bool

    private var connected: Bool {
        if case .connected = state { return true }
        return false
    }

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(connected: connected,
                                                 volumeBucket: bucket(volume),
                                                 muted: muted))
    }

    /// Cache the icon at 32 discrete volume levels to keep cache size bounded
    /// while still giving smooth visual feedback (~3% increments).
    private func bucket(_ v: Float) -> Int {
        let clamped = max(0, min(1, v))
        return Int((clamped * 31).rounded())
    }
}

enum MenuBarIconRenderer {
    private struct Key: Hashable { let connected: Bool; let bucket: Int; let muted: Bool }
    private static var cache: [Key: NSImage] = [:]

    static func image(connected: Bool, volumeBucket: Int, muted: Bool) -> NSImage {
        let k = Key(connected: connected, bucket: volumeBucket, muted: muted)
        if let c = cache[k] { return c }
        let img = render(connected: connected, volume: Float(volumeBucket) / 31.0, muted: muted)
        img.isTemplate = true
        cache[k] = img
        return img
    }

    /// 18-pt logical size (renders to 36px @2x). Black-on-clear so isTemplate
    /// auto-tints to the menubar foreground.
    private static func render(connected: Bool, volume: Float, muted: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
        ctx.setShouldAntialias(true)

        let c = CGPoint(x: 9, y: 8)
        let r: CGFloat = 5.0

        // Knob outline.
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.4)
        ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Indicator rotates with system master volume.
        //
        // Sweep: 7:30 (down-left) → 4:30 (down-right) clockwise, 270°.
        //   In CG bitmap coords (+y up, 0 rad = +x):
        //   v=0 → 7:30 = -135° = -3π/4 (lower-left)
        //   v=1 → 4:30 = -45°  = -π/4 (lower-right)
        // Going from v=0 to v=1 we sweep clockwise (decreasing angle).
        // Mute draws the indicator vertically pointing down as a "no signal"
        // cue, so the icon visibly differs from "volume = 0".
        let angle: CGFloat
        if muted {
            angle = -.pi / 2   // straight down
        } else {
            let start: CGFloat = -3 * .pi / 4
            let end: CGFloat   = -.pi / 4
            angle = start + (end - start) * CGFloat(max(0, min(1, volume)))
        }
        let pInner = CGPoint(x: c.x + cos(angle) * r * 0.25,
                             y: c.y + sin(angle) * r * 0.25)
        let pOuter = CGPoint(x: c.x + cos(angle) * r * 0.85,
                             y: c.y + sin(angle) * r * 0.85)
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.6)
        ctx.move(to: pInner); ctx.addLine(to: pOuter)
        ctx.strokePath()

        // LED fan: dots fill in like a battery meter.
        //   filled count = 0 (muted), 0 (v<6%), 1 (v<40%), 2 (v<73%), 3 (v≥73%)
        let fanR = r + 2.6
        let dotR: CGFloat = 0.95
        let angles: [CGFloat] = [.pi * 0.78, .pi * 0.50, .pi * 0.22]
        let filled: Int = {
            if muted || volume < 0.06 { return 0 }
            if volume < 0.40 { return 1 }
            if volume < 0.73 { return 2 }
            return 3
        }()
        // Fill order: middle first, then alternate.
        let fillIndices: [Int] = [1, 0, 2]   // center, then left, then right
        let toFill = Set(fillIndices.prefix(filled))
        for (i, a) in angles.enumerated() {
            let p = CGPoint(x: c.x + cos(a) * fanR, y: c.y + sin(a) * fanR)
            let rect = CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2)
            if toFill.contains(i) {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(0.7)
                ctx.strokeEllipse(in: rect)
            }
        }

        // Disconnected = a small diagonal slash across the knob, so it's
        // visually distinct without losing the volume / mute affordances.
        if !connected {
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.2)
            ctx.move(to: CGPoint(x: c.x - r * 0.6, y: c.y - r * 0.6))
            ctx.addLine(to: CGPoint(x: c.x + r * 0.6, y: c.y + r * 0.6))
            ctx.strokePath()
        }
        return image
    }
}
