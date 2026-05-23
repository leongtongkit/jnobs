import Foundation
import Darwin

/// Event-driven serial port for the Turn Up device.
///
/// Settings empirically required for the device to keep talking, derived
/// from observing USB CDC-ACM traffic:
///   • 8N1, no flow control
///   • DTR + RTS asserted (without these, the device falls silent within
///     seconds — confirmed by toggling the lines and watching the read
///     stream go dead)
///   • discard in/out buffers on open
///   • event-driven reads via a kqueue DispatchSource (no polling, no actor
///     contention with writes)
///
/// Reads fire `onData` on an internal serial queue; the owner re-dispatches to
/// its own actor. Writes are funneled through the same queue so they never
/// interleave with each other.
final class SerialPort: @unchecked Sendable {
    private var fd: Int32 = -1
    private let path: String
    private let queue = DispatchQueue(label: "net.jfound.jnobs.serial")
    private var readSource: DispatchSourceRead?

    private var onData: (@Sendable ([UInt8]) -> Void)?
    private var onClosed: (@Sendable () -> Void)?

    init(path: String) { self.path = path }

    /// Open + configure + start the read loop. Callbacks fire on an internal
    /// queue.
    func open(
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) throws {
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if f < 0 { throw SerialError.openFailed(errno: errno, path: path) }
        fd = f
        do {
            try configureTty(fd: f)
            assertModemLines(fd: f)   // DTR + RTS
            discardBuffers(fd: f)
        } catch {
            Darwin.close(f); fd = -1
            throw error
        }
        self.onData = onData
        self.onClosed = onClosed
        startReadSource()
    }

    func close() {
        queue.sync {
            readSource?.cancel()
            readSource = nil
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }

    var isOpen: Bool { fd >= 0 }

    /// Write a frame. Best-effort, funneled through the serial queue. Briefly
    /// polls for writability so a momentarily-full TX buffer doesn't drop data,
    /// but never blocks indefinitely.
    func write(_ data: [UInt8]) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var written = 0
            var spins = 0
            data.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                while written < data.count {
                    let n = Darwin.write(self.fd, base.advanced(by: written), data.count - written)
                    if n < 0 {
                        if errno == EAGAIN {
                            // Wait up to 20ms total for the buffer to drain.
                            var pfd = pollfd(fd: self.fd, events: Int16(POLLOUT), revents: 0)
                            _ = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 5) }
                            spins += 1
                            if spins > 4 { break }   // give up on this frame
                            continue
                        }
                        break   // hard error; read source will detect close
                    }
                    written += n
                    spins = 0
                }
            }
        }
    }

    // MARK: - Read source

    private func startReadSource() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(self.fd, $0.baseAddress, 1024) }
            if n > 0 {
                self.onData?(Array(buf.prefix(n)))
            } else if n == 0 {
                // EOF — device went away.
                self.handleClosed()
            } else if errno != EAGAIN {
                self.handleClosed()
            }
        }
        src.setCancelHandler { }
        readSource = src
        src.resume()
    }

    private func handleClosed() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        onClosed?()
    }

    // MARK: - Device discovery

    static func findDevicePath() -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .first
            .map { "/dev/\($0)" }
    }
}

// MARK: - tty / modem configuration

private func configureTty(fd: Int32) throws {
    var attrs = termios()
    if tcgetattr(fd, &attrs) != 0 { throw SerialError.configureFailed(errno: errno) }
    attrs.c_iflag = 0
    attrs.c_oflag = 0
    attrs.c_lflag = 0
    var c = attrs.c_cflag
    c &= ~tcflag_t(CSIZE)
    c |= tcflag_t(CS8)
    c |= tcflag_t(CREAD | CLOCAL)
    c &= ~tcflag_t(PARENB)
    c &= ~tcflag_t(CSTOPB)
    attrs.c_cflag = c
    withUnsafeMutablePointer(to: &attrs.c_cc) { ptr in
        ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { p in
            p[Int(VMIN)] = 0
            p[Int(VTIME)] = 0
        }
    }
    cfsetispeed(&attrs, speed_t(TUProtocol.baudRate))
    cfsetospeed(&attrs, speed_t(TUProtocol.baudRate))
    if tcsetattr(fd, TCSANOW, &attrs) != 0 { throw SerialError.configureFailed(errno: errno) }
}

/// Assert DTR and RTS. The Turn Up firmware stops responding without DTR.
private func assertModemLines(fd: Int32) {
    var bits: Int32 = TIOCM_DTR | TIOCM_RTS
    _ = ioctl(fd, TIOCMBIS, &bits)
}

private func discardBuffers(fd: Int32) {
    tcflush(fd, TCIOFLUSH)
}

enum SerialError: Error, CustomStringConvertible {
    case openFailed(errno: Int32, path: String)
    case notOpen
    case configureFailed(errno: Int32)

    var description: String {
        switch self {
        case .openFailed(let e, let p): return "open \(p) failed: errno=\(e) \(String(cString: strerror(e)))"
        case .notOpen: return "serial port not open"
        case .configureFailed(let e): return "tty config failed: errno=\(e) \(String(cString: strerror(e)))"
        }
    }
}
