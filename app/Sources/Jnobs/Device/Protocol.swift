import Foundation

/// Turn Up serial protocol — clean-room reverse-engineered from USB traffic observation.
/// See PROTOCOL.md at the project root.
enum TUProtocol {
    static let startByte: UInt8 = 0xFE
    static let endByte:   UInt8 = 0xFF
    static let baudRate:  Int32 = 115200
    static let knobCount = 5
    static let ledsPerKnob = 3
    static let colorFrameSize = 48

    enum MessageType: UInt8 {
        case ping        = 0x01   // host → device
        case health      = 0x02   // device → host (autonomous, 500 ms)
        case knobPos     = 0x03   // device → host
        case knobBatch   = 0x04   // device → host
        case setLights   = 0x05   // host → device
        case buttonPress = 0x06   // device → host
        case buttonUp    = 0x07   // device → host
        case deviceId    = 0x08   // device → host

        var expectedLength: Int {
            switch self {
            case .ping:        return 3
            case .health:      return 3
            case .knobPos:     return 6
            case .knobBatch:   return 13
            case .setLights:   return 48
            case .buttonPress: return 4
            case .buttonUp:    return 4
            case .deviceId:    return 7
            }
        }
    }
}

/// One inbound frame decoded.
enum DeviceEvent: Sendable, Equatable {
    case health
    case knobChanged(index: Int, raw: Int, percent: Double)
    case knobBatch(percents: [Double])
    case buttonPressed(index: Int)
    case buttonReleased(index: Int)
    case deviceId(UInt32)
}

/// Streaming frame parser — feed it bytes, get events.
struct FrameParser {
    private var buf: [UInt8] = []

    /// Maximum buffer size before we reset (defensive).
    private let maxBuffer = 256

    mutating func feed(_ bytes: ArraySlice<UInt8>) -> [DeviceEvent] {
        buf.append(contentsOf: bytes)
        if buf.count > maxBuffer {
            buf.removeFirst(buf.count - maxBuffer)
        }
        var out: [DeviceEvent] = []
        while let ev = nextEvent() { out.append(ev) }
        return out
    }

    private mutating func nextEvent() -> DeviceEvent? {
        while !buf.isEmpty && buf[0] != TUProtocol.startByte {
            buf.removeFirst()
        }
        guard buf.count >= 3 else { return nil }
        guard let kind = TUProtocol.MessageType(rawValue: buf[1]) else {
            // unknown type — drop the start byte and resync
            buf.removeFirst()
            return nil
        }
        let need = kind.expectedLength
        guard buf.count >= need else { return nil }
        // sanity: last byte must be end
        guard buf[need - 1] == TUProtocol.endByte else {
            buf.removeFirst()
            return nil
        }
        let frame = Array(buf[0..<need])
        buf.removeFirst(need)
        return Self.decode(kind: kind, frame: frame)
    }

    private static func decode(kind: TUProtocol.MessageType, frame: [UInt8]) -> DeviceEvent? {
        switch kind {
        case .health:
            return .health
        case .knobPos:
            let idx = Int(frame[2])
            let raw = (Int(frame[3]) << 8) | Int(frame[4])
            let clamped = min(raw, 1023)
            let pct = Double(clamped) / 10.23
            guard idx >= 0 && idx < TUProtocol.knobCount else { return nil }
            return .knobChanged(index: idx, raw: clamped, percent: pct)
        case .knobBatch:
            var pcts: [Double] = []
            for i in 0..<TUProtocol.knobCount {
                let raw = (Int(frame[2 + i*2]) << 8) | Int(frame[3 + i*2])
                pcts.append(Double(min(raw, 1023)) / 10.23)
            }
            return .knobBatch(percents: pcts)
        case .buttonPress:
            return .buttonPressed(index: Int(frame[2]))
        case .buttonUp:
            return .buttonReleased(index: Int(frame[2]))
        case .deviceId:
            let id = (UInt32(frame[2]) << 24) | (UInt32(frame[3]) << 16)
                   | (UInt32(frame[4]) << 8)  |  UInt32(frame[5])
            return .deviceId(id)
        case .ping, .setLights:
            return nil   // host-side opcodes — shouldn't arrive inbound
        }
    }
}

/// Outbound frame encoders.
enum FrameEncoder {
    static func ping() -> [UInt8] {
        [TUProtocol.startByte, TUProtocol.MessageType.ping.rawValue, TUProtocol.endByte]
    }

    /// 48-byte color frame. knobColors is 5 × 3 RGB values (one per LED).
    static func setLights(knobColors: [[RGB]]) -> [UInt8] {
        precondition(knobColors.count == TUProtocol.knobCount)
        var out = [UInt8](repeating: 0, count: TUProtocol.colorFrameSize)
        out[0] = TUProtocol.startByte
        out[1] = TUProtocol.MessageType.setLights.rawValue
        out[47] = TUProtocol.endByte
        for k in 0..<TUProtocol.knobCount {
            let leds = knobColors[k]
            precondition(leds.count == TUProtocol.ledsPerKnob)
            for j in 0..<TUProtocol.ledsPerKnob {
                let base = k * 9 + j * 3 + 2
                out[base]     = leds[j].r
                out[base + 1] = leds[j].g
                out[base + 2] = leds[j].b
            }
        }
        return out
    }
}

/// 8-bit RGB color.
struct RGB: Sendable, Equatable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    static let off = RGB(r: 0, g: 0, b: 0)
    static let red = RGB(r: 255, g: 0, b: 0)
    static let green = RGB(r: 0, g: 255, b: 0)
    static let blue = RGB(r: 0, g: 0, b: 255)
    static let white = RGB(r: 255, g: 255, b: 255)
    static let mint = RGB(r: 0, g: 220, b: 70)  // Turn Up default

    /// Linearly scale brightness (0..1).
    func scaled(_ factor: Double) -> RGB {
        let f = max(0, min(1, factor))
        return RGB(
            r: UInt8(Double(r) * f),
            g: UInt8(Double(g) * f),
            b: UInt8(Double(b) * f)
        )
    }

    /// Apply 8-bit gamma correction so low intensities remain visible on the RGB LEDs.
    func gammaCorrected() -> RGB {
        RGB(r: TUProtocol.gamma8[Int(r)],
            g: TUProtocol.gamma8[Int(g)],
            b: TUProtocol.gamma8[Int(b)])
    }

    /// Linear blend between two colors (0 = self, 1 = other).
    func blended(with other: RGB, fraction t: Double) -> RGB {
        let f = max(0, min(1, t))
        return RGB(
            r: UInt8(Double(r) * (1 - f) + Double(other.r) * f),
            g: UInt8(Double(g) * (1 - f) + Double(other.g) * f),
            b: UInt8(Double(b) * (1 - f) + Double(other.b) * f)
        )
    }
}

extension TUProtocol {
    /// Standard 8-bit gamma-2.2 LUT, computed from `pow(i/255, 2.2) * 255`.
    /// Used to perceptually linearize the RGB LEDs at low brightness.
    static let gamma8: [UInt8] = (0...255).map { i in
        UInt8(min(255.0, (pow(Double(i) / 255.0, 2.2) * 255.0).rounded()))
    }
}
