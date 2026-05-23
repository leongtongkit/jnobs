// Standalone Core Audio process-tap probe.
//
// Validates the SoundSource-style pipeline on macOS 14.2+:
//   1. enumerate audio processes (bundle ID + pid)
//   2. tap a target app's output (muted so we own its audio)
//   3. build a private aggregate device {tap + output device}
//   4. IOProc: measure captured RMS, apply gain, write to output
//
// Build: swiftc tap_probe.swift -o tap_probe -framework CoreAudio -framework AudioToolbox -framework Foundation
// Run:   ./tap_probe                 (lists audio processes)
//        ./tap_probe <bundleID> [gain 0..1]   (taps + routes that app)
import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Property helpers

func sysObject() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ elem: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
}

func getData<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = a
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    let s = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value)
    return s == noErr ? value : nil
}

func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
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

func getCFString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
    var a = a
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString? = nil
    let s = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
    }
    return s == noErr ? (value as String?) : nil
}

// MARK: - Process enumeration

struct AudioProc { let objectID: AudioObjectID; let pid: pid_t; let bundleID: String }

func listAudioProcesses() -> [AudioProc] {
    let objs = getArray(sysObject(), addr(kAudioHardwarePropertyProcessObjectList), AudioObjectID.self)
    var out: [AudioProc] = []
    for o in objs {
        let pid = getData(o, addr(kAudioProcessPropertyPID), pid_t(0)) ?? -1
        let bid = getCFString(o, addr(kAudioProcessPropertyBundleID)) ?? ""
        out.append(AudioProc(objectID: o, pid: pid, bundleID: bid))
    }
    return out
}

func defaultOutputDevice() -> AudioObjectID? {
    getData(sysObject(), addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
}

func deviceUID(_ dev: AudioObjectID) -> String? {
    getCFString(dev, addr(kAudioDevicePropertyDeviceUID))
}

func deviceName(_ dev: AudioObjectID) -> String {
    getCFString(dev, addr(kAudioObjectPropertyName)) ?? "<?>"
}

// MARK: - Main

let args = CommandLine.arguments

if args.count < 2 {
    print("Audio processes (bundleID — pid — objID):")
    for p in listAudioProcesses() where !p.bundleID.isEmpty {
        print("  \(p.bundleID)  —  pid \(p.pid)  —  obj \(p.objectID)")
    }
    if let dev = defaultOutputDevice() {
        print("\nDefault output: \(deviceName(dev))  uid=\(deviceUID(dev) ?? "?")")
    }
    print("\nUsage: ./tap_probe <bundleID> [gain 0..1]")
    exit(0)
}

let target = args[1]
let gain = Float(args.count > 2 ? Double(args[2]) ?? 1.0 : 1.0)

// Match by bundle ID, or by "pid:NNNN" for CLI processes with no bundle ID.
let proc: AudioProc? = {
    let procs = listAudioProcesses()
    if target.hasPrefix("pid:"), let pid = pid_t(target.dropFirst(4)) {
        return procs.first(where: { $0.pid == pid })
    }
    return procs.first(where: { $0.bundleID == target })
}()

guard let proc else {
    print("No audio process matched \(target). Is it running and playing audio?")
    print("Run with no args to list candidates. Use pid:NNNN to match by PID.")
    exit(1)
}
print("Tapping \(proc.bundleID.isEmpty ? "pid \(proc.pid)" : proc.bundleID) (pid \(proc.pid), obj \(proc.objectID)), gain \(gain)")

guard let outDev = defaultOutputDevice(), let outUID = deviceUID(outDev) else {
    print("No default output device."); exit(1)
}
print("Routing to: \(deviceName(outDev)) (\(outUID))")

// 1. Tap description — this single process, stereo mixdown, muted (we own it).
let tapDesc = CATapDescription(stereoMixdownOfProcesses: [proc.objectID])
tapDesc.name = "TurnUp probe tap"
tapDesc.isPrivate = true
tapDesc.muteBehavior = CATapMuteBehavior(rawValue: 2) ?? .unmuted  // mutedWhenTapped

var tapID: AudioObjectID = 0
let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard tapStatus == noErr else {
    print("AudioHardwareCreateProcessTap failed: \(tapStatus) (TCC permission? needs audio-recording grant)")
    exit(1)
}
print("Created tap obj \(tapID)")

guard let tapUID = getCFString(tapID, addr(kAudioTapPropertyUID)) else {
    print("Failed to read tap UID"); exit(1)
}

// Read the tap's stream format so the real engine interprets buffers correctly.
if let fmt = getData(tapID, addr(kAudioTapPropertyFormat), AudioStreamBasicDescription()) {
    print(String(format: "Tap format: %.0f Hz, %u ch, %u bits, flags 0x%X, bytesPerFrame %u",
                 fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mBitsPerChannel,
                 fmt.mFormatFlags, fmt.mBytesPerFrame))
    let interleaved = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    print("  interleaved: \(interleaved), float: \((fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0)")
}

// 2. Private aggregate device combining the output device + the tap.
let aggUID = "tech.turnup.probe.agg"
let aggDict: [String: Any] = [
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceNameKey: "TurnUp Probe Aggregate",
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
    kAudioAggregateDeviceTapAutoStartKey: true,
]
var aggID: AudioObjectID = 0
let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
guard aggStatus == noErr else {
    print("AudioHardwareCreateAggregateDevice failed: \(aggStatus)")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}
print("Created aggregate obj \(aggID)")

// 3. IOProc: measure input RMS, scale by gain, copy input → output.
nonisolated(unsafe) var frameCount = 0
nonisolated(unsafe) var lastLog = Date()
let g = gain

var ioProcID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) {
    (now, inInput, inTime, outOutput, outTime) in
    let inBL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    let outBL = UnsafeMutableAudioBufferListPointer(outOutput)
    var sumSq: Double = 0
    var n = 0
    // Copy input (tap) → output (device), scaled by gain; accumulate RMS.
    for (idx, inBuf) in inBL.enumerated() {
        guard idx < outBL.count else { break }
        let outBuf = outBL[idx]
        let count = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size
        guard let inPtr = inBuf.mData?.assumingMemoryBound(to: Float.self),
              let outPtr = outBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let outCount = Int(outBuf.mDataByteSize) / MemoryLayout<Float>.size
        for i in 0..<min(count, outCount) {
            let s = inPtr[i]
            sumSq += Double(s * s); n += 1
            outPtr[i] = s * g
        }
    }
    frameCount += n
    if n > 0, Date().timeIntervalSince(lastLog) > 0.5 {
        let rms = (sumSq / Double(n)).squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -120
        FileHandle.standardError.write("  tap RMS \(String(format: "%6.1f", db)) dB  (\(n) samples)\n".data(using: .utf8)!)
        lastLog = Date()
    }
}
guard ioStatus == noErr, ioProcID != nil else {
    print("AudioDeviceCreateIOProcIDWithBlock failed: \(ioStatus)")
    AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

AudioDeviceStart(aggID, ioProcID)
print("Running for 12s — play audio in \(target); you should see RMS rise. Ctrl-C to stop early.")

// Clean teardown on exit.
func teardown() {
    if let p = ioProcID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
}
signal(SIGINT) { _ in teardown(); exit(0) }

Thread.sleep(forTimeInterval: 12)
teardown()
print("Done. Total samples captured: \(frameCount)")
