import Foundation
import AppKit

/// Synthesize macOS media keys (play/pause, next, previous) via NSEvent.
///
/// These are not regular keycodes — they're system-defined events with subtype
/// `NSSystemDefined` and a packed `keyCode`. We post via CGEvent for reach.
enum MediaKeys {
    static let playPause: Int32 = 16        // NX_KEYTYPE_PLAY
    static let next: Int32 = 17             // NX_KEYTYPE_NEXT
    static let previous: Int32 = 18         // NX_KEYTYPE_PREVIOUS
    static let fastForward: Int32 = 19      // NX_KEYTYPE_FAST
    static let rewind: Int32 = 20           // NX_KEYTYPE_REWIND
    static let mute: Int32 = 7              // NX_KEYTYPE_MUTE
    static let volumeUp: Int32 = 0          // NX_KEYTYPE_SOUND_UP
    static let volumeDown: Int32 = 1        // NX_KEYTYPE_SOUND_DOWN

    /// Send a tap (down then up) for the given media key.
    static func tap(_ keyCode: Int32) {
        post(keyCode: keyCode, keyDown: true)
        post(keyCode: keyCode, keyUp: true)
    }

    private static func post(keyCode: Int32, keyDown: Bool = false, keyUp: Bool = false) {
        let flags: Int32 = keyDown ? 0xA00 : 0xB00
        let data1: Int = (Int(keyCode) << 16) | Int(flags)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags << 16)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,  // kIOHIDPower / aux control
            data1: data1,
            data2: -1
        ) else { return }
        if let cg = event.cgEvent {
            cg.post(tap: .cghidEventTap)
        }
    }
}
