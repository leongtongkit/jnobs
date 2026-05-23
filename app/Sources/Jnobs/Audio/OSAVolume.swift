import Foundation

/// Last-resort volume control via AppleScript.
///
/// Slower than CoreAudio (~40 ms vs ~1 ms) but works regardless of device
/// capabilities — it routes through the same path as the F11/F12 keys.
enum OSAVolume {
    /// Set system output volume, 0..100 (truncated to int).
    static func setOutputVolume(_ pct: Int) {
        let p = max(0, min(100, pct))
        run("set volume output volume \(p)")
    }

    /// Set system input volume, 0..100.
    static func setInputVolume(_ pct: Int) {
        let p = max(0, min(100, pct))
        run("set volume input volume \(p)")
    }

    static func setOutputMuted(_ on: Bool) {
        run("set volume output muted \(on)")
    }

    private static func run(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var err: NSDictionary?
        _ = script.executeAndReturnError(&err)
    }
}
