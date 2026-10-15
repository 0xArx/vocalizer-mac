// Lists the processes Core Audio knows about and groups helper processes under their app
// (Safari plays through com.apple.WebKit.GPU, Chrome through "Google Chrome Helper").

import AppKit
import CoreAudio

public struct AudioSource: Identifiable, Hashable {
    /// Responsible app's bundle id or pid, or "all".
    public let id: String
    public let name: String
    public let pids: [pid_t]
    public let objectIDs: [AudioObjectID]
    public let isPlaying: Bool
    public var isAll: Bool { id == "all" }

    public init(id: String, name: String, pids: [pid_t], objectIDs: [AudioObjectID], isPlaying: Bool) {
        self.id = id; self.name = name; self.pids = pids; self.objectIDs = objectIDs; self.isPlaying = isPlaying
    }

    public static let all = AudioSource(id: "all", name: "All audio", pids: [], objectIDs: [], isPlaying: true)
    /// Everything routed through the Vocalizer virtual output device (keeps video in sync).
    public static let virtualDevice = AudioSource(id: "vocalizer-device", name: "Vocalizer device", pids: [], objectIDs: [], isPlaying: true)
    public var isVirtualDevice: Bool { id == AudioSource.virtualDevice.id }
}

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
        guard err == noErr else { throw CAError(err, "get \(fourCC(selector))") }
        return value
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw CAError(err, "size \(fourCC(selector))") }
        var out = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        err = out.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
        guard err == noErr else { throw CAError(err, "get \(fourCC(selector))") }
        return out
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let s = try? get(object, selector, Unmanaged<CFString>?.none) else { return nil }
        return s.takeRetainedValue() as String
    }

    static func fourCC(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? "\(v)"
    }
}

public struct CAError: LocalizedError {
    public let status: OSStatus
    public let what: String
    public init(_ status: OSStatus, _ what: String) { self.status = status; self.what = what }
    public var errorDescription: String? { "\(what) failed (\(status) '\(CA.fourCC(UInt32(bitPattern: status)))')" }
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

public enum AudioProcesses {
    /// Core Audio process object for a pid (our own, to exclude it from a global tap).
    public static func object(for pid: pid_t) -> AudioObjectID? {
        var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return err == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Apps with audio processes, playing ones first. Our own process is left out, and so are
    /// background daemons unless they are playing (or `includeBackground`).
    public static func list(includeBackground: Bool = false) -> [AudioSource] {
        let objects = (try? CA.getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                                        AudioObjectID(0))) ?? []
        let me = getpid()
        var groups: [String: (name: String, pids: [pid_t], objs: [AudioObjectID], playing: Bool, regular: Bool)] = [:]
        for obj in objects {
            guard let pid = try? CA.get(obj, kAudioProcessPropertyPID, pid_t(0)), pid != me else { continue }
            let playing = ((try? CA.get(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0
            let bundle = CA.string(obj, kAudioProcessPropertyBundleID) ?? ""
            let owner = responsibleFn?(pid) ?? pid
            let app = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid) ?? NSRunningApplication(processIdentifier: pid)
            if owner == me { continue }
            let key = app?.bundleIdentifier ?? (bundle.isEmpty ? "pid:\(pid)" : bundle)
            var name = app?.localizedName ?? (bundle.isEmpty ? "pid \(pid)" : bundle)
            if bundle.hasPrefix("com.apple.WebKit"), app?.bundleIdentifier == nil { name = "Safari / WebKit" }
            var g = groups[key] ?? (name, [], [], false, false)
            g.pids.append(pid); g.objs.append(obj); g.playing = g.playing || playing
            g.regular = g.regular || app?.activationPolicy == .regular
            groups[key] = g
        }
        return groups.filter { includeBackground || $0.value.playing || $0.value.regular }.map { AudioSource(id: $0.key, name: $0.value.name, pids: $0.value.pids, objectIDs: $0.value.objs, isPlaying: $0.value.playing) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    public static func defaultOutputDevice() throws -> AudioDeviceID {
        try CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
    }

    public static func uid(of device: AudioDeviceID) -> String? { CA.string(device, kAudioDevicePropertyDeviceUID) }

    public static let vocalizerDeviceUID = "Vocalizer_UID"

    public static func devices() -> [AudioDeviceID] {
        (try? CA.getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID(0))) ?? []
    }

    public static func device(uid: String) -> AudioDeviceID? { devices().first { self.uid(of: $0) == uid } }

    /// The installed Vocalizer virtual device (Driver/), if any.
    public static func vocalizerDevice() -> AudioDeviceID? { device(uid: vocalizerDeviceUID) }

    public static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var addr = CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    public static func setDefaultOutput(_ device: AudioDeviceID) throws {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = device
        let err = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        guard err == noErr else { throw CAError(err, "set default output") }
    }

    /// Sets the output latency (frames) that the Vocalizer device reports to apps.
    public static func setVocalizerLatency(frames: Int) throws {
        guard let dev = vocalizerDevice() else { throw CAError(-1, "Vocalizer device not installed") }
        var addr = CA.address(0x766C_6174) // 'vlat'
        var num = NSNumber(value: Int32(frames)) as CFNumber
        let err = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<CFNumber>.size), &num)
        guard err == noErr else { throw CAError(err, "set Vocalizer latency") }
    }

    // MARK: volume / mute (main element, output scope)

    public static func volume(_ device: AudioDeviceID) -> Float? {
        try? CA.get(device, kAudioDevicePropertyVolumeScalar, Float32(0), scope: kAudioObjectPropertyScopeOutput)
    }

    public static func isMuted(_ device: AudioDeviceID) -> Bool? {
        (try? CA.get(device, kAudioDevicePropertyMute, UInt32(0), scope: kAudioObjectPropertyScopeOutput)).map { $0 != 0 }
    }

    /// Sets the volume on the main element, or on channels 1 and 2 if the device only has per-channel volume.
    @discardableResult
    public static func setVolume(_ device: AudioDeviceID, _ value: Float) -> Bool {
        var v = Float32(max(0, min(1, value)))
        for elements in [[kAudioObjectPropertyElementMain], [UInt32(1), UInt32(2)]] {
            var ok = true
            for el in elements {
                var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: el)
                var settable: DarwinBoolean = false
                guard AudioObjectHasProperty(device, &addr), AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
                      settable.boolValue, AudioObjectSetPropertyData(device, &addr, 0, nil, 4, &v) == noErr else { ok = false; break }
            }
            if ok { return true }
        }
        return false
    }

    @discardableResult
    public static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var m: UInt32 = muted ? 1 : 0
        return AudioObjectHasProperty(device, &addr) && AudioObjectSetPropertyData(device, &addr, 0, nil, 4, &m) == noErr
    }

    /// Sets the name the Vocalizer device shows in Control Center / Sound settings.
    public static func setVocalizerName(_ name: String) {
        guard let dev = vocalizerDevice() else { return }
        var addr = CA.address(0x766E_616D) // 'vnam'
        var str = name as CFString
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<CFString>.size), &str)
    }

    /// Real output devices the user can play on (not the Vocalizer device, not our private aggregates).
    public static func realOutputs() -> [(id: AudioDeviceID, uid: String, name: String)] {
        devices().compactMap { d in
            guard hasOutput(d), let uid = uid(of: d), !uid.lowercased().hasPrefix("vocalizer") else { return nil }
            return (d, uid, name(of: d) ?? uid)
        }
    }

    public static func outputLatencyFrames(_ device: AudioDeviceID) -> UInt32 {
        (try? CA.get(device, kAudioDevicePropertyLatency, UInt32(0), scope: kAudioObjectPropertyScopeOutput)) ?? 0
    }
    public static func name(of device: AudioDeviceID) -> String? { CA.string(device, kAudioObjectPropertyName) }
}
