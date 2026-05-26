import Foundation
import os

/// Holds the streaming frame parser. Touched only from the serial port's
/// internal queue (single-threaded), so unchecked-Sendable is safe.
private final class ParserBox: @unchecked Sendable {
    private var parser = FrameParser()
    func feed(_ bytes: [UInt8]) -> [DeviceEvent] { parser.feed(ArraySlice(bytes)) }
}

/// Top-level device lifecycle owner.
///
/// Discovers the Turn Up device, opens it, consumes an ordered event stream,
/// publishes state, accepts color frames, and reconnects on disconnect or
/// heartbeat loss.
@MainActor
final class DeviceManager: ObservableObject {
    private let log = Logger(subsystem: "net.jfound.jnobs", category: "Device")

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastDeviceId: UInt32?
    @Published private(set) var knobPercents: [Double] = [0, 0, 0, 0, 0]
    /// Transient: true for ~140 ms when the corresponding button is pressed.
    /// Used by the UI to flash the on-screen pad in time with the real device.
    @Published private(set) var buttonFlash: [Bool] = [false, false, false, false, false]

    enum State: Equatable {
        case disconnected
        case connecting(path: String)
        case connected(path: String)
        case error(String)
    }

    private var eventSubscribers: [(DeviceEvent) -> Void] = []
    private var port: SerialPort?
    private var consumeTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var lastHealth = Date()
    private var reconnecting = false

    func addSubscriber(_ cb: @escaping (DeviceEvent) -> Void) {
        eventSubscribers.append(cb)
    }

    func start() {
        connect()
    }

    func sendColorFrame(_ frame: [UInt8]) {
        port?.write(frame)
    }

    // MARK: - Connection lifecycle

    private func connect() {
        reconnecting = false
        guard let path = SerialPort.findDevicePath() else {
            state = .disconnected
            scheduleRetry(after: 1.0)
            return
        }
        state = .connecting(path: path)
        let p = SerialPort(path: path)
        let parserBox = ParserBox()
        let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream(bufferingPolicy: .unbounded)

        do {
            try p.open(
                onData: { bytes in
                    for ev in parserBox.feed(bytes) { continuation.yield(ev) }
                },
                onClosed: {
                    continuation.finish()
                }
            )
        } catch {
            log.error("connect failed: \(String(describing: error), privacy: .public)")
            state = .error(String(describing: error))
            scheduleRetry(after: 1.5)
            return
        }

        port = p
        lastHealth = Date()
        state = .connected(path: path)
        log.info("connected on \(path, privacy: .public)")
        p.write(FrameEncoder.ping())
        startWatchdog()

        // Ordered consumer — runs until the stream finishes (device closed).
        consumeTask = Task { @MainActor [weak self] in
            for await ev in stream {
                guard let self else { break }
                if case .health = ev { self.lastHealth = Date() }
                self.handleEvent(ev)
            }
            self?.handleDisconnect(reason: "stream ended")
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Defensive re-arm every tick. macOS PM has been observed
                // to silently drop modem lines during long idle, which
                // makes the Turn Up firmware fall silent. Microseconds-
                // cheap; no point gating on silence.
                self.port?.reassertModemLines()
                let silence = Date().timeIntervalSince(self.lastHealth)
                if silence > 12 {
                    // Truly gone — even the recovery ping didn't help.
                    self.log.warning("no heartbeat in \(Int(silence))s; reconnecting")
                    self.handleDisconnect(reason: "heartbeat lost (\(Int(silence))s)")
                } else if silence > 5 {
                    // Soft recovery before nuclear teardown. The device
                    // responds to `fe 01 ff` with deviceID + knob batch
                    // and resumes its 500 ms heartbeat. If silence persists
                    // past 12s, the next tick will tear down.
                    self.log.info("no heartbeat in \(Int(silence))s; recovery ping")
                    self.port?.write(FrameEncoder.ping())
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func handleDisconnect(reason: String) {
        guard !reconnecting else { return }
        reconnecting = true
        log.info("disconnect: \(reason, privacy: .public)")
        watchdog?.invalidate(); watchdog = nil
        consumeTask?.cancel(); consumeTask = nil
        port?.close(); port = nil
        state = .disconnected
        scheduleRetry(after: 1.0)
    }

    private func scheduleRetry(after seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.connect()
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ ev: DeviceEvent) {
        switch ev {
        case .deviceId(let id):
            lastDeviceId = id
        case .knobBatch(let pcts):
            knobPercents = pcts
        case .knobChanged(let i, _, let pct):
            if i < knobPercents.count { knobPercents[i] = pct }
        case .buttonPressed(let i):
            flashButton(i)
        default: break
        }
        for sub in eventSubscribers { sub(ev) }
    }

    private func flashButton(_ i: Int) {
        guard buttonFlash.indices.contains(i) else { return }
        buttonFlash[i] = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, self.buttonFlash.indices.contains(i) else { return }
            self.buttonFlash[i] = false
        }
    }
}
