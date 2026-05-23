import Foundation
import CoreAudio
import AudioToolbox
import os

/// CoreAudio HAL wrapper for the default output / input devices.
///
/// Sets master volume / mute on default output, and mic volume / mute on
/// default input. Tries multiple property selectors because devices vary:
/// some expose VolumeScalar on the main element, some only per-channel, and
/// modern devices route through VirtualMainVolume (`vmvc`).
enum CoreAudioVolume {
    private static let log = Logger(subsystem: "net.jfound.jnobs", category: "CoreAudio")

    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`
    private static let kVirtualMainVolume = AudioObjectPropertySelector(0x766D7663) // 'vmvc'

    // MARK: - Default device discovery

    private static func defaultOutput() -> AudioDeviceID? {
        defaultDevice(.defaultOutputDevice)
    }

    private static func defaultInput() -> AudioDeviceID? {
        defaultDevice(.defaultInputDevice)
    }

    private enum DefaultKind {
        case defaultOutputDevice
        case defaultInputDevice

        var selector: AudioObjectPropertySelector {
            switch self {
            case .defaultOutputDevice: return kAudioHardwarePropertyDefaultOutputDevice
            case .defaultInputDevice:  return kAudioHardwarePropertyDefaultInputDevice
            }
        }
    }

    private static func defaultDevice(_ kind: DefaultKind) -> AudioDeviceID? {
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let s = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &dev
        )
        return s == noErr ? dev : nil
    }

    /// Get human-readable name of a device, for diagnostics.
    static func deviceName(_ dev: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let s = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name)
        return s == noErr ? (name as String) : "<unknown>"
    }

    // MARK: - Master volume

    static func getMasterVolume() -> Float? {
        guard let dev = defaultOutput() else { return nil }
        return readScalar(dev: dev, scope: kAudioDevicePropertyScopeOutput)
    }

    @discardableResult
    static func setMasterVolume(_ value: Float) -> Bool {
        guard let dev = defaultOutput() else { return false }
        let ok = writeScalar(dev: dev, scope: kAudioDevicePropertyScopeOutput, value: value)
        if !ok {
            // Benign — caller falls back to the osascript route. Debug-level only.
            log.debug("CoreAudio volume not settable on \(deviceName(dev), privacy: .public); using fallback")
        }
        return ok
    }

    static func setMasterMute(_ on: Bool) -> Bool {
        guard let dev = defaultOutput() else { return false }
        return setMute(of: dev, scope: kAudioDevicePropertyScopeOutput, mute: on)
    }

    static func getMasterMute() -> Bool? {
        guard let dev = defaultOutput() else { return nil }
        return getMute(of: dev, scope: kAudioDevicePropertyScopeOutput)
    }

    // MARK: - Microphone

    static func getMicVolume() -> Float? {
        guard let dev = defaultInput() else { return nil }
        return readScalar(dev: dev, scope: kAudioDevicePropertyScopeInput)
    }

    @discardableResult
    static func setMicVolume(_ value: Float) -> Bool {
        guard let dev = defaultInput() else { return false }
        return writeScalar(dev: dev, scope: kAudioDevicePropertyScopeInput, value: value)
    }

    static func setMicMute(_ on: Bool) -> Bool {
        guard let dev = defaultInput() else { return false }
        return setMute(of: dev, scope: kAudioDevicePropertyScopeInput, mute: on)
    }

    static func getMicMute() -> Bool? {
        guard let dev = defaultInput() else { return nil }
        return getMute(of: dev, scope: kAudioDevicePropertyScopeInput)
    }

    // MARK: - Internals

    private static func readScalar(dev: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        // Try, in order of preference:
        // 1. VirtualMainVolume on main element (modern, works on most devices)
        // 2. VolumeScalar on main element
        // 3. VolumeScalar averaged across channels 1 & 2
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kVirtualMainVolume, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
        ]
        for (sel, elem) in selectors {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
            if AudioObjectHasProperty(dev, &addr) {
                var v: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr {
                    return v
                }
            }
        }
        // Channels 1, 2
        var sum: Float32 = 0
        var n: Int = 0
        for ch: UInt32 in 1...2 {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: ch
            )
            if AudioObjectHasProperty(dev, &addr) {
                var v: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr {
                    sum += v; n += 1
                }
            }
        }
        return n > 0 ? sum / Float(n) : nil
    }

    @discardableResult
    private static func writeScalar(dev: AudioDeviceID, scope: AudioObjectPropertyScope, value: Float) -> Bool {
        let v: Float32 = max(0, min(1, value))
        let size = UInt32(MemoryLayout<Float32>.size)

        // 1. VirtualMainVolume — handles devices that don't expose VolumeScalar.
        if trySet(dev: dev, scope: scope, sel: kVirtualMainVolume,
                  elem: kAudioObjectPropertyElementMain, value: v, size: size) {
            return true
        }
        // 2. VolumeScalar on main element.
        if trySet(dev: dev, scope: scope, sel: kAudioDevicePropertyVolumeScalar,
                  elem: kAudioObjectPropertyElementMain, value: v, size: size) {
            return true
        }
        // 3. Channel-level fallback.
        var any = false
        for ch: UInt32 in 1...2 {
            if trySet(dev: dev, scope: scope, sel: kAudioDevicePropertyVolumeScalar,
                      elem: ch, value: v, size: size) {
                any = true
            }
        }
        return any
    }

    private static func trySet(
        dev: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        sel: AudioObjectPropertySelector,
        elem: AudioObjectPropertyElement,
        value: Float32,
        size: UInt32
    ) -> Bool {
        var v = value
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        let s = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v)
        return s == noErr
    }

    private static func setMute(of dev: AudioDeviceID, scope: AudioObjectPropertyScope, mute: Bool) -> Bool {
        var m: UInt32 = mute ? 1 : 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &addr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue {
                let s = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
                return s == noErr
            }
        }
        return false
    }

    private static func getMute(of dev: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool? {
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &addr) {
            let s = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m)
            if s == noErr { return m != 0 }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Logs everything we know about the current output device.
    static func logDiagnostics() {
        guard let dev = defaultOutput() else { log.warning("no default output device"); return }
        log.info("default output: id=\(dev), name=\(deviceName(dev), privacy: .public)")
        let scope = kAudioDevicePropertyScopeOutput
        log.info("VirtualMainVolume settable: \(isSettable(dev: dev, scope: scope, sel: kVirtualMainVolume, elem: kAudioObjectPropertyElementMain), privacy: .public)")
        log.info("VolumeScalar/main settable: \(isSettable(dev: dev, scope: scope, sel: kAudioDevicePropertyVolumeScalar, elem: kAudioObjectPropertyElementMain), privacy: .public)")
        log.info("VolumeScalar/ch1 settable: \(isSettable(dev: dev, scope: scope, sel: kAudioDevicePropertyVolumeScalar, elem: 1), privacy: .public)")
        log.info("VolumeScalar/ch2 settable: \(isSettable(dev: dev, scope: scope, sel: kAudioDevicePropertyVolumeScalar, elem: 2), privacy: .public)")
        log.info("Current readout: \(readScalar(dev: dev, scope: scope) ?? -1, privacy: .public)")
    }

    private static func isSettable(
        dev: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        sel: AudioObjectPropertySelector,
        elem: AudioObjectPropertyElement
    ) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
        guard AudioObjectHasProperty(dev, &addr) else { return "absent" }
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr {
            return settable.boolValue ? "YES" : "no"
        }
        return "error"
    }
}
