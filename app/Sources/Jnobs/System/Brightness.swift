import Foundation
import IOKit
import CoreGraphics

/// Display brightness control.
///
/// Built-in displays support brightness via the private DisplayServices
/// framework. We resolve symbols dynamically so the app doesn't link a private
/// SPI at compile time. External displays without DDC/CI return false silently.
enum Brightness {
    /// Set built-in display brightness, 0..1.
    @discardableResult
    static func setBuiltInBrightness(_ value: Float) -> Bool {
        guard let sym = setSymbol else { return false }
        let v = max(0, min(1, value))
        return sym(builtInDisplay, v) == 0
    }

    /// Read current built-in display brightness.
    static func getBuiltInBrightness() -> Float? {
        guard let sym = getSymbol else { return nil }
        var v: Float = 0
        return sym(builtInDisplay, &v) == 0 ? v : nil
    }

    // MARK: - Internals

    private typealias DSSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias DSGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    nonisolated(unsafe) private static let displayServicesHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
               RTLD_LAZY)
    }()

    nonisolated(unsafe) private static let setSymbol: DSSetBrightness? = {
        guard let h = displayServicesHandle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: DSSetBrightness.self)
    }()

    nonisolated(unsafe) private static let getSymbol: DSGetBrightness? = {
        guard let h = displayServicesHandle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: DSGetBrightness.self)
    }()

    private static var builtInDisplay: CGDirectDisplayID {
        // CGMainDisplayID is usually the built-in on laptops / first display on desktops.
        CGMainDisplayID()
    }
}
