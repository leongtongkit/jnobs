import Foundation
import CoreAudio
import AppKit

/// Shared Core Audio property-access helpers.
enum CA {
    static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ elem: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
    }

    static func get<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = a
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let s = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        return s == noErr ? value : nil
    }

    static func array<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
        var a = a
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        var sz = size
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, ptr) == noErr else { return [] }
        let typed = ptr.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func string(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
        var a = a
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let s = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        return s == noErr ? (value as String?) : nil
    }
}

/// An audio-producing process as Core Audio sees it.
struct AudioProcessInfo: Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
}

enum AudioProcesses {
    /// All processes Core Audio currently tracks (some have empty bundle IDs).
    static func all() -> [AudioProcessInfo] {
        CA.array(CA.system, CA.addr(kAudioHardwarePropertyProcessObjectList), AudioObjectID.self).map { o in
            AudioProcessInfo(
                objectID: o,
                pid: CA.get(o, CA.addr(kAudioProcessPropertyPID), pid_t(0)) ?? -1,
                bundleID: CA.string(o, CA.addr(kAudioProcessPropertyBundleID)) ?? ""
            )
        }
    }

    /// Process object IDs belonging to an app, including helper processes
    /// (e.g. `com.google.Chrome.helper` for `com.google.Chrome`).
    static func objectIDs(forBundleID bundleID: String) -> [AudioObjectID] {
        all().filter {
            $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".")
        }.map(\.objectID)
    }

    /// Distinct user-facing app bundle IDs currently producing/able to produce
    /// audio. Filters out system daemons / faceless services so the picker
    /// only shows things the user recognizes ("Spotify", "Chrome", etc.).
    static func appBundleIDs() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in all() where !p.bundleID.isEmpty {
            // Collapse helpers to their parent app where obvious.
            let base = p.bundleID
                .replacingOccurrences(of: ".helper", with: "")
                .replacingOccurrences(of: ".Helper", with: "")
            guard isUserFacingApp(bundleID: base) else { continue }
            if seen.insert(base).inserted { out.append(base) }
        }
        return out.sorted { AppNames.short($0).localizedCaseInsensitiveCompare(AppNames.short($1)) == .orderedAscending }
    }

    /// True if `bundleID` belongs to an app the user would recognize: it has
    /// a real `.app` bundle on disk and its Info.plist marks it as a regular
    /// (Dock-visible) application — not a daemon, agent, or system service.
    private static func isUserFacingApp(bundleID: String) -> Bool {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        // Read the bundle's LSUIElement / LSBackgroundOnly markers. We accept:
        //   - regular foreground apps (neither flag set)
        //   - LSUIElement=true menubar apps (still user-facing, e.g. some chat clients)
        // We reject: LSBackgroundOnly daemons.
        if let bundle = Bundle(url: url) {
            if let backgroundOnly = bundle.infoDictionary?["LSBackgroundOnly"] as? Bool, backgroundOnly {
                return false
            }
        }
        return true
    }
}

enum AudioDevices {
    static func defaultOutput() -> AudioObjectID? {
        CA.get(CA.system, CA.addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
    }

    static func uid(_ dev: AudioObjectID) -> String? {
        CA.string(dev, CA.addr(kAudioDevicePropertyDeviceUID))
    }

    static func name(_ dev: AudioObjectID) -> String {
        CA.string(dev, CA.addr(kAudioObjectPropertyName)) ?? "Unknown"
    }

    /// All output-capable devices as (uid, name).
    static func outputs() -> [(uid: String, name: String)] {
        let ids = CA.array(CA.system, CA.addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
        return ids.compactMap { dev in
            // Has output streams?
            let streams = CA.array(dev, CA.addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput), AudioStreamID.self)
            guard !streams.isEmpty, let u = uid(dev) else { return nil }
            return (u, name(dev))
        }
    }
}
