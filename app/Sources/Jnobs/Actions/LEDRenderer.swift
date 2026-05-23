import Foundation

/// Computes the 5×3 LED state from current knob percentages + bindings, and
/// pushes color frames to the device. Runs the device's `setLights` ~30 Hz.
@MainActor
final class LEDRenderer: ObservableObject {
    private weak var deviceManager: DeviceManager?
    private weak var router: ActionRouter?

    /// The latest 5×3 RGB matrix sent to the hardware. UI observes this to
    /// mirror the physical LED fan in the menubar and Console panels.
    @Published private(set) var currentSlots: [[RGB]] = Array(
        repeating: Array(repeating: .off, count: 3),
        count: 5
    )

    private var animationTick: Double = 0   // for rainbow / pulse effects
    private var timer: Timer?

    init(deviceManager: DeviceManager, router: ActionRouter) {
        self.deviceManager = deviceManager
        self.router = router
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common mode keeps it firing during menu tracking / window drags.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func tick() {
        animationTick += 1.0 / 30.0
        guard let dm = deviceManager, let router = router else { return }
        let cfg = router.config
        let pcts = dm.knobPercents
        // Measured: input knob ID i and LED byte slot i are the same physical
        // knob (both run left→right). Straight 1:1 mapping.
        var slots: [[RGB]] = []
        for i in 0..<TUProtocol.knobCount {
            let pct = i < pcts.count ? pcts[i] / 100.0 : 0
            slots.append(renderKnob(i: i, percent: pct, binding: cfg.lights[i], router: router))
        }
        let bytes = FrameEncoder.setLights(knobColors: slots)
        dm.sendColorFrame(bytes)
        currentSlots = slots
    }

    private func renderKnob(i: Int, percent: Double, binding: LightBinding, router: ActionRouter) -> [RGB] {
        let leds = TUProtocol.ledsPerKnob
        let bright = router.ledBrightness

        // VU-meter substitution: when this knob is bound to a routed app's
        // volume, replace the knob-position-driven fill ratio with the live
        // RMS level for that route. Sqrt-shape because RMS is power-ish and
        // perceived loudness is log-ish — gives a more reactive fan that
        // doesn't sit pegged near 0.
        var fillRatio = percent
        if i < router.config.knobs.count,
           case .appVolume(let bid) = router.config.knobs[i],
           !bid.isEmpty,
           let state = router.tapRouter.states[bid],
           state.status == .built {
            fillRatio = Double(sqrtf(state.level))
        }

        switch binding {
        case .off:
            return Array(repeating: .off, count: leds)

        case .singleColor(let c):
            let out = c.scaled(bright).gammaCorrected()
            return Array(repeating: out, count: leds)

        case .positionFill(let c):
            // Each LED segment is fully on if the value reaches it, else a
            // dim "track" so the fan always reads as alive. For VU-meter
            // mode (appVolume knob), the value is the live RMS level.
            var arr: [RGB] = []
            for j in 0..<leds {
                let threshold = Double(j + 1) / Double(leds)
                let lit = fillRatio >= threshold - 0.5 / Double(leds)
                let scale = lit ? bright : bright * 0.18
                arr.append(c.scaled(scale).gammaCorrected())
            }
            return arr

        case .positionBlend(let low, let high):
            let mid = low.blended(with: high, fraction: fillRatio).scaled(bright).gammaCorrected()
            return Array(repeating: mid, count: leds)

        case .microphoneStatus(let active, let muted):
            let c = router.micMuted ? muted : active
            return Array(repeating: c.scaled(bright).gammaCorrected(), count: leds)

        case .rainbow:
            var arr: [RGB] = []
            for j in 0..<leds {
                let phase = (animationTick * 0.6) + Double(i) * 0.15 + Double(j) * 0.1
                arr.append(hsv(phase: phase).scaled(bright).gammaCorrected())
            }
            return arr
        }
    }

    /// Pure-hue HSV with fully saturated rainbow output.
    private func hsv(phase: Double) -> RGB {
        let h = phase.truncatingRemainder(dividingBy: 1.0)
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p: Double = 0
        let q = 1 - f
        let t = f
        let (r, g, b): (Double, Double, Double)
        switch i % 6 {
        case 0: (r, g, b) = (1, t, p)
        case 1: (r, g, b) = (q, 1, p)
        case 2: (r, g, b) = (p, 1, t)
        case 3: (r, g, b) = (p, q, 1)
        case 4: (r, g, b) = (t, p, 1)
        default:(r, g, b) = (1, p, q)
        }
        return RGB(r: UInt8(r * 255), g: UInt8(g * 255), b: UInt8(b * 255))
    }
}
