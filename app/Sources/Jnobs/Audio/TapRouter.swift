import Foundation
import CoreAudio
import AudioToolbox
import AppKit   // NSWorkspace for sleep/wake notifications
import Combine
import os

/// Per-app audio engine built on Core Audio process taps (macOS 14.2+).
///
/// For each controlled app we create a muted tap on its processes and a private
/// aggregate device combining {chosen output device + that tap}, then run an
/// IOProc that copies the tapped audio to the output with a per-app gain.
///
/// • per-app **volume** = the gain multiplier
/// • per-app **output routing** = which device the aggregate targets
/// • per-app **mute** = the gain multiplier forced to 0 (restored from
///   `lastUnmutedGain` when unmuted)
///
/// State is exposed via `@Published states` so the Console can render
/// indicators per route (built / pending / broken) plus a live RMS level
/// updated at ~30 Hz from each IOProc.
@MainActor
final class TapRouter: ObservableObject {
    private let log = Logger(subsystem: "net.jfound.jnobs", category: "TapRouter")

    // MARK: - Public state

    /// Snapshot of every route the user has configured, keyed by bundleID.
    /// Updated whenever route state changes and whenever the 30 Hz level
    /// timer ticks (for VU meter rendering).
    @Published private(set) var states: [String: RouteState] = [:]

    // MARK: - Internal state

    /// One live route per controlled app (keyed by bundle ID).
    private final class Route {
        let bundleID: String
        var outputUID: String?            // nil = follow system default output
        var tapID: AudioObjectID = 0
        var aggID: AudioObjectID = 0
        var ioProcID: AudioDeviceIOProcID?
        /// Heap gain cell read by the real-time IOProc (no ARC on the audio thread).
        let gainPtr: UnsafeMutablePointer<Float>
        /// Heap level cell written by IOProc (peak-hold RMS), polled by UI timer.
        let levelPtr: UnsafeMutablePointer<Float>

        init(bundleID: String, gain: Float) {
            self.bundleID = bundleID
            self.gainPtr = .allocate(capacity: 1)
            self.gainPtr.initialize(to: gain)
            self.levelPtr = .allocate(capacity: 1)
            self.levelPtr.initialize(to: 0)
        }
        deinit {
            gainPtr.deallocate()
            levelPtr.deallocate()
        }
    }

    /// Currently *built* routes (one live tap + aggregate per bundleID).
    private var routes: [String: Route] = [:]
    /// What the user configured — drives reconciliation when processes
    /// appear/disappear and survives temporary build failures.
    private struct Wanted {
        var gain: Float
        var outputUID: String?
        var muted: Bool
        var lastUnmutedGain: Float   // restored on unmute
    }
    private var wanted: [String: Wanted] = [:]

    private var processListenerInstalled = false
    private var deviceListenerInstalled = false
    private var sleepWakeRegistered = false
    private var levelTimer: Timer?

    init() {
        installProcessListListener()
        installDeviceListListener()
        installSleepWakeObservers()
        startLevelTimer()
    }

    // MARK: - Public API

    /// Set an app's volume (0…1). Persists in `wanted` so the route is rebuilt
    /// if/when the audio process appears later.
    func setVolume(bundleID: String, gain: Float) {
        let g = max(0, min(1, gain))
        var w = wanted[bundleID] ?? Wanted(gain: g, outputUID: nil, muted: false, lastUnmutedGain: g)
        w.gain = g
        if !w.muted { w.lastUnmutedGain = g }
        wanted[bundleID] = w
        applyGainToRoute(bundleID)
        if routes[bundleID] == nil { tryBuild(bundleID: bundleID) }
        publishState(bundleID)
    }

    /// Route an app's audio to a specific output device (by UID). Pass nil to
    /// follow the system default again.
    func setOutput(bundleID: String, deviceUID: String?) {
        let existing = wanted[bundleID]
        let g = existing?.gain ?? (routes[bundleID]?.gainPtr.pointee ?? 1.0)
        teardown(bundleID: bundleID)
        wanted[bundleID] = Wanted(
            gain: g,
            outputUID: deviceUID,
            muted: existing?.muted ?? false,
            lastUnmutedGain: existing?.lastUnmutedGain ?? g
        )
        tryBuild(bundleID: bundleID)
        publishState(bundleID)
    }

    /// Toggle or set the route's mute state. When muted, gain is forced to 0
    /// without forgetting the user's intended level.
    func setMuted(bundleID: String, _ muted: Bool) {
        guard var w = wanted[bundleID] else { return }
        if w.muted == muted { return }
        if muted {
            w.lastUnmutedGain = w.gain
            w.muted = true
        } else {
            w.muted = false
            w.gain = w.lastUnmutedGain
        }
        wanted[bundleID] = w
        applyGainToRoute(bundleID)
        publishState(bundleID)
    }

    func currentVolume(bundleID: String) -> Float? {
        wanted[bundleID]?.gain ?? routes[bundleID].map { $0.gainPtr.pointee }
    }

    func currentOutput(bundleID: String) -> String? {
        wanted[bundleID]?.outputUID ?? routes[bundleID]?.outputUID
    }

    func isMuted(bundleID: String) -> Bool {
        wanted[bundleID]?.muted ?? false
    }

    /// All bundle IDs we *want* routed (built or pending).
    var routedBundleIDs: [String] { Array(wanted.keys) }

    /// Tear down a route, restoring the app's normal audio path. Also drops
    /// it from `wanted` so the listener won't rebuild it.
    func clearRoute(bundleID: String) {
        teardown(bundleID: bundleID)
        wanted.removeValue(forKey: bundleID)
        states.removeValue(forKey: bundleID)
    }

    func clearAll() {
        for id in Array(routes.keys) { teardown(bundleID: id) }
        wanted.removeAll()
        states.removeAll()
    }

    /// Snapshot of the device-list change handler hook, exposed so the rest
    /// of the app (sleep/wake, hotplug) can prompt a reconciliation.
    func reconcileNow() {
        reconcileWithProcessList()
    }

    // MARK: - Reconciliation

    private func tryBuild(bundleID: String) {
        guard let w = wanted[bundleID] else { return }
        let effectiveGain: Float = w.muted ? 0 : w.gain
        if let r = buildRoute(bundleID: bundleID, gain: effectiveGain, outputUID: w.outputUID) {
            routes[bundleID] = r
        }
        publishState(bundleID)
    }

    private func applyGainToRoute(_ bundleID: String) {
        guard let r = routes[bundleID], let w = wanted[bundleID] else { return }
        r.gainPtr.pointee = w.muted ? 0 : w.gain
    }

    /// Install a Core Audio listener that fires whenever the system's audio
    /// process list changes. We use it to (re)build any routes whose target
    /// app just appeared, and tear down routes whose target just quit.
    private func installProcessListListener() {
        guard !processListenerInstalled else { return }
        var addr = CA.addr(kAudioHardwarePropertyProcessObjectList)
        let st = AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.reconcileWithProcessList()
            }
        }
        if st == noErr {
            processListenerInstalled = true
            log.info("process-list listener installed")
            DiagSink.shared.info("TapRouter", "process-list listener installed")
        } else {
            log.error("process-list listener install failed: \(st)")
            DiagSink.shared.error("TapRouter", "process-list listener install failed: OSStatus=\(st)")
        }
    }

    private func reconcileWithProcessList() {
        for (bid, w) in wanted {
            let procIDs = AudioProcesses.objectIDs(forBundleID: bid)
            let built = routes[bid] != nil
            let avail = !procIDs.isEmpty
            switch (built, avail) {
            case (true, false):
                log.info("\(bid, privacy: .public): process gone, tearing down")
                DiagSink.shared.info("TapRouter", "\(bid): process gone, tearing down")
                teardown(bundleID: bid)
                publishState(bid)
            case (false, true):
                log.info("\(bid, privacy: .public): process appeared, building route")
                DiagSink.shared.info("TapRouter", "\(bid): process appeared, building route")
                let effective: Float = w.muted ? 0 : w.gain
                if let r = buildRoute(bundleID: bid, gain: effective, outputUID: w.outputUID) {
                    routes[bid] = r
                }
                publishState(bid)
            default:
                break
            }
        }
    }

    // MARK: - Hotplug + sleep/wake

    private func installDeviceListListener() {
        guard !deviceListenerInstalled else { return }
        var addr = CA.addr(kAudioHardwarePropertyDevices)
        let st = AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.handleDeviceListChange() }
        }
        if st == noErr {
            deviceListenerInstalled = true
            log.info("device-list listener installed")
            DiagSink.shared.info("TapRouter", "device-list listener installed")
        } else {
            log.error("device-list listener install failed: \(st)")
            DiagSink.shared.error("TapRouter", "device-list listener install failed: OSStatus=\(st)")
        }
    }

    /// Tear down routes whose target output device has disappeared; rebuild
    /// pending routes whose target device just (re)appeared.
    private func handleDeviceListChange() {
        let outputs = Set(AudioDevices.outputs().map(\.uid))
        for (bid, route) in routes {
            guard let target = route.outputUID, !target.isEmpty else { continue }
            if !outputs.contains(target) {
                log.info("\(bid, privacy: .public): target device \(target, privacy: .public) gone, tearing down")
                DiagSink.shared.info("TapRouter", "\(bid): target output \(target) gone")
                teardown(bundleID: bid)
                publishState(bid)
            }
        }
        for (bid, w) in wanted where routes[bid] == nil {
            let procExists = !AudioProcesses.objectIDs(forBundleID: bid).isEmpty
            let deviceExists = w.outputUID.flatMap { outputs.contains($0) ? true : nil } ?? true
            if procExists && deviceExists {
                log.info("\(bid, privacy: .public): device now available, rebuilding")
                DiagSink.shared.info("TapRouter", "\(bid): device available, rebuilding")
                tryBuild(bundleID: bid)
            }
        }
    }

    private func installSleepWakeObservers() {
        guard !sleepWakeRegistered else { return }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSleep() }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
        sleepWakeRegistered = true
        log.info("sleep/wake observers installed")
        DiagSink.shared.info("TapRouter", "sleep/wake observers installed")
    }

    /// Pre-sleep: tear down every aggregate cleanly. They tend to come back
    /// in zombie states across sleep otherwise.
    private func handleSleep() {
        log.info("sleep: tearing down all routes")
        DiagSink.shared.info("TapRouter", "sleep: tearing down all routes")
        for id in Array(routes.keys) {
            teardown(bundleID: id)
            publishState(id)
        }
    }

    /// Post-wake: rebuild every wanted route. The process-list listener will
    /// also fire shortly after, so this is the primary mechanism but we're
    /// belt-and-braces.
    private func handleWake() {
        log.info("wake: rebuilding all routes")
        DiagSink.shared.info("TapRouter", "wake: rebuilding all routes")
        // Small delay lets coreaudiod fully restore its device list.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            for (bid, _) in self.wanted where self.routes[bid] == nil {
                self.tryBuild(bundleID: bid)
            }
        }
    }

    // MARK: - State publishing + level polling

    private func publishState(_ bundleID: String) {
        guard let w = wanted[bundleID] else {
            states.removeValue(forKey: bundleID)
            return
        }
        let route = routes[bundleID]
        let status: RouteState.Status = route != nil
            ? .built
            : (AudioProcesses.objectIDs(forBundleID: bundleID).isEmpty ? .pending : .broken)
        let level = route?.levelPtr.pointee ?? 0
        states[bundleID] = RouteState(
            bundleID: bundleID,
            status: status,
            outputUID: w.outputUID,
            gain: w.gain,
            muted: w.muted,
            level: level
        )
    }

    /// 30 Hz timer that re-publishes states with fresh RMS levels for the
    /// VU meter and any "is this route actually flowing audio?" indicator.
    private func startLevelTimer() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLevels() }
        }
    }

    private func refreshLevels() {
        var changed = false
        for (bid, r) in routes {
            let lvl = r.levelPtr.pointee
            // Apply a tiny decay so the meter falls when audio stops, even
            // if the IOProc isn't firing (e.g., app silent but route alive).
            let decayed = max(0, lvl * 0.85)
            r.levelPtr.pointee = decayed
            if var s = states[bid], abs(s.level - decayed) > 0.001 {
                s.level = decayed
                states[bid] = s
                changed = true
            }
        }
        if !changed { /* no-op: keep CPU low when nothing's playing */ }
    }

    // MARK: - Route construction

    private func buildRoute(bundleID: String, gain: Float, outputUID: String?) -> Route? {
        let procIDs = AudioProcesses.objectIDs(forBundleID: bundleID)
        guard !procIDs.isEmpty else {
            log.info("no audio processes for \(bundleID, privacy: .public) yet; will retry when it plays")
            return nil
        }

        // Resolve the output device UID (chosen, or current default).
        let outUID: String
        if let u = outputUID {
            outUID = u
        } else if let def = AudioDevices.defaultOutput(), let u = AudioDevices.uid(def) {
            outUID = u
        } else {
            log.error("no output device available")
            return nil
        }

        // 1. Muted tap over the app's processes. `stereoMixdownOfProcesses:`
        //    is the known-good config — flipping `isMixdown = false` after
        //    init makes `AudioHardwareCreateProcessTap` reject every tap
        //    (regression we hit 2026-05-23). Quality cost: extra SRC stage
        //    when output device ≠ 48 kHz. Accepted.
        let desc = CATapDescription(stereoMixdownOfProcesses: procIDs)
        desc.name = "Jnobs:\(bundleID)"
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior(rawValue: 2) ?? .unmuted  // mutedWhenTapped

        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapStatus == noErr,
              let tapUID = CA.string(tapID, CA.addr(kAudioTapPropertyUID)) else {
            log.error("tap creation failed for \(bundleID, privacy: .public): OSStatus=\(tapStatus)")
            DiagSink.shared.error("TapRouter", "tap creation failed for \(bundleID): OSStatus=\(tapStatus)")
            return nil
        }

        // 2. Private aggregate {output device + tap}. Sanitize the bundleID
        //    for use in the aggregate UID — Unity-style IDs like
        //    `unity.Blizzard Entertainment.Hearthstone` contain spaces that
        //    Core Audio rejects. Drift compensation cranked to max quality.
        let safeID = String(bundleID.map { c -> Character in
            (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "_"
        })
        let aggUID = "net.jfound.jnobs.agg.\(safeID)"
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceNameKey: "Jnobs \(bundleID)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                "drift": true,
                "drift quality": Int(kAudioAggregateDriftCompensationMaxQuality),
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var aggID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
        guard aggStatus == noErr else {
            log.error("aggregate creation failed for \(bundleID, privacy: .public): OSStatus=\(aggStatus) aggUID=\(aggUID, privacy: .public)")
            DiagSink.shared.error("TapRouter", "aggregate creation failed for \(bundleID): OSStatus=\(aggStatus)")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let route = Route(bundleID: bundleID, gain: gain)
        route.tapID = tapID
        route.aggID = aggID
        route.outputUID = outputUID

        // 3. IOProc: copy tapped input → output, scaled by gain, while
        //    sampling peak-hold RMS into levelPtr for the VU meter.
        let gainPtr = route.gainPtr
        let levelPtr = route.levelPtr
        var ioProcID: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) {
            (_, inInput, _, outOutput, _) in
            let g = gainPtr.pointee
            let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let outBL = UnsafeMutableAudioBufferListPointer(outOutput)
            let pairCount = min(inBL.count, outBL.count)

            var sumSq: Float = 0
            var sampleCount: Int = 0

            for idx in 0..<pairCount {
                let ib = inBL[idx], ob = outBL[idx]
                guard let ip = ib.mData?.assumingMemoryBound(to: Float.self),
                      let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(Int(ib.mDataByteSize), Int(ob.mDataByteSize)) / MemoryLayout<Float>.size
                for i in 0..<n {
                    let s = ip[i]
                    op[i] = s * g
                    sumSq += s * s
                }
                sampleCount += n
            }
            // Peak-hold envelope (post-gain, so muted route reads 0).
            if sampleCount > 0 {
                let rms = sqrtf(sumSq / Float(sampleCount)) * g
                let prev = levelPtr.pointee
                levelPtr.pointee = max(rms, prev * 0.92)
            }
            // Zero any output buffers we didn't fill (avoid stale noise).
            for idx in pairCount..<outBL.count {
                if let op = outBL[idx].mData { memset(op, 0, Int(outBL[idx].mDataByteSize)) }
            }
        }
        guard st == noErr, let proc = ioProcID else {
            log.error("IOProc creation failed for \(bundleID, privacy: .public)")
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        route.ioProcID = proc
        AudioDeviceStart(aggID, proc)
        log.info("route up: \(bundleID, privacy: .public) → \(outUID, privacy: .public) gain \(gain)")
        DiagSink.shared.info("TapRouter", "route up: \(bundleID) → \(outUID) gain=\(String(format: "%.2f", gain))")
        return route
    }

    private func teardown(bundleID: String) {
        guard let r = routes.removeValue(forKey: bundleID) else { return }
        if let p = r.ioProcID {
            AudioDeviceStop(r.aggID, p)
            AudioDeviceDestroyIOProcID(r.aggID, p)
        }
        if r.aggID != 0 { AudioHardwareDestroyAggregateDevice(r.aggID) }
        if r.tapID != 0 { AudioHardwareDestroyProcessTap(r.tapID) }
        log.info("route down: \(bundleID, privacy: .public)")
        DiagSink.shared.info("TapRouter", "route down: \(bundleID)")
    }
}

// MARK: - Route state

/// Observable snapshot of one route. Re-emitted on user actions and on the
/// 30 Hz level timer (for VU meter rendering).
struct RouteState: Equatable, Sendable {
    enum Status: Sendable {
        /// Tap + aggregate + IOProc are live and audio is flowing through us.
        case built
        /// User configured this route but the target app isn't producing audio
        /// yet — the process-list listener will build it when it appears.
        case pending
        /// We tried to build and Core Audio rejected us. Visible in the UI so
        /// the user knows something needs attention.
        case broken
    }

    let bundleID: String
    let status: Status
    let outputUID: String?
    let gain: Float
    let muted: Bool
    var level: Float    // 0...1 RMS (post-gain) updated at ~30 Hz
}
