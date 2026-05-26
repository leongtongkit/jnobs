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

    /// Per-knob per-LED ON/OFF latch for positionFill hysteresis. Without
    /// this, a fillRatio that hovers near a threshold (very common in
    /// VU-meter mode on game audio) flickers the LED at that boundary
    /// every frame. Hysteresis: turn ON at the normal threshold, turn OFF
    /// only when the value drops 5% below it.
    private var positionFillLit: [[Bool]] = Array(
        repeating: Array(repeating: false, count: TUProtocol.ledsPerKnob),
        count: TUProtocol.knobCount
    )

    /// Per-knob smoothed VU fillRatio. Real VU meters have fast attack
    /// and slow release so spikes register but the needle doesn't twitch;
    /// without this the raw RMS swings 30%+ frame-to-frame on bursty game
    /// audio and overwhelms any reasonable hysteresis band. Tuned for
    /// ~200 ms visual release at the 30 Hz tick.
    private var smoothedFill: [Double] = Array(
        repeating: 0,
        count: TUProtocol.knobCount
    )

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
            // Sqrt-shape because RMS is power-ish and perceived loudness
            // is log-ish — keeps the fan reactive without sitting near 0.
            var raw = Double(sqrtf(state.level))
            // Noise gate: SRC stage + tiny digital noise floor ~0.01-0.02
            // even on silence; snap below that to 0 so the first LED isn't
            // perpetually twitching at ambient.
            if raw < 0.03 { raw = 0 }
            // VU ballistics: fast attack (rise instantly to peak), slow
            // release (0.85 per 30 Hz frame ≈ 200 ms time constant).
            let prev = smoothedFill[i]
            let smoothed = max(raw, prev * 0.85)
            smoothedFill[i] = smoothed
            fillRatio = smoothed
        } else if i < smoothedFill.count {
            // Knob not in VU mode this tick — reset smoothing so a future
            // re-bind to .appVolume starts clean instead of decaying from
            // a stale value.
            smoothedFill[i] = 0
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
            // mode (appVolume knob), the value is the live RMS level — and
            // we apply hysteresis so a level hovering near a threshold
            // doesn't flicker the LED at that boundary (per-frame on/off).
            var arr: [RGB] = []
            for j in 0..<leds {
                let onThreshold  = Double(j + 1) / Double(leds) - 0.5 / Double(leds)
                let offThreshold = onThreshold - 0.05
                let wasLit = positionFillLit[i][j]
                let lit = wasLit ? (fillRatio > offThreshold) : (fillRatio >= onThreshold)
                positionFillLit[i][j] = lit
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
