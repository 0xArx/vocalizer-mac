// Asks macOS whether this app may record system audio, instead of guessing from silence
// (a paused video or a page that keeps its audio stream open looks like "no sound" but is not a problem).
import Foundation

enum AudioPermission {
    enum State { case granted, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let preflight: Preflight? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: Preflight.self)
    }()

    /// System Audio Recording permission (TCC service "kTCCServiceAudioCapture").
    static var systemAudio: State {
        guard let preflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }
}
