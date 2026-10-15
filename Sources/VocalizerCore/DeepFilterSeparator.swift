// "Ultra fast" mode: DeepFilterNet3 (github.com/Rikorose/DeepFilterNet, MIT/Apache-2.0), a speech
// enhancement model that treats music as noise. 48 kHz, 10 ms frames, 2 frames of look-ahead, on the CPU.
// libdf.dylib (built from libDF with `--features capi`) is loaded at runtime; one state per channel.

import Foundation

public final class DeepFilterSeparator: Separating {
    public let sampleRate = 48_000.0
    public let step: Int
    /// Output sample k is input sample k - streamDelay (measured, see tools / README).
    public let streamDelay: Int
    public var stem: OutputStem = .vocals
    public private(set) var lastStepTime = 0.0
    public var lastModelTime: Double { lastStepTime }

    private typealias CreateFn = @convention(c) (UnsafePointer<CChar>, Float, UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias LengthFn = @convention(c) (OpaquePointer?) -> Int
    private typealias ProcessFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Float
    private typealias FreeFn = @convention(c) (OpaquePointer?) -> Void
    private let process: ProcessFn, free: FreeFn
    private var states: [OpaquePointer?] = []
    private var pendL: [Float] = [], pendR: [Float] = []
    private var inL: [Float], inR: [Float], outL: [Float], outR: [Float]
    private var dryL: [Float], dryR: [Float] // delay line for the karaoke stem (mix - voice)
    private var dryPos = 0

    /// Default latency of DeepFilterNet3: (fft 960 - hop 480) + 2 look-ahead frames of 480.
    public static let modelDelay = 1440

    public init(library: URL, model: URL, attenuationDb: Float = 100) throws {
        guard let lib = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            throw NSError(domain: "DeepFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load \(library.lastPathComponent): \(String(cString: dlerror()))"])
        }
        func sym<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(lib, name) else { throw NSError(domain: "DeepFilter", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"]) }
            return unsafeBitCast(p, to: T.self)
        }
        let create = try sym("df_create", CreateFn.self)
        let length = try sym("df_get_frame_length", LengthFn.self)
        process = try sym("df_process_frame", ProcessFn.self)
        free = try sym("df_free", FreeFn.self)
        for _ in 0..<2 {
            guard let st = model.path.withCString({ create($0, attenuationDb, nil) }) else {
                throw NSError(domain: "DeepFilter", code: 3, userInfo: [NSLocalizedDescriptionKey: "df_create failed"])
            }
            states.append(st)
        }
        step = length(states[0])
        streamDelay = Self.modelDelay
        inL = [Float](repeating: 0, count: step); inR = inL; outL = inL; outR = inL
        dryL = [Float](repeating: 0, count: streamDelay); dryR = dryL
    }

    deinit { for s in states { free(s) } }

    public func reset() { pendL.removeAll(); pendR.removeAll() }

    public func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        pendL.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
        pendR.append(contentsOf: UnsafeBufferPointer(start: right, count: count))
    }

    @discardableResult
    public func process(emit: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) throws -> Bool {
        guard pendL.count >= step else { return false }
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<step { inL[i] = pendL[i]; inR[i] = pendR[i] }
        pendL.removeFirst(step); pendR.removeFirst(step)
        _ = process(states[0], &inL, &outL)
        _ = process(states[1], &inR, &outR)
        if stem == .music {
            for i in 0..<step {
                let dl = dryL[dryPos], dr = dryR[dryPos]
                dryL[dryPos] = inL[i]; dryR[dryPos] = inR[i]
                dryPos = (dryPos + 1) % dryL.count
                outL[i] = dl - outL[i]; outR[i] = dr - outR[i]
            }
        } else {
            for i in 0..<step {
                dryL[dryPos] = inL[i]; dryR[dryPos] = inR[i]
                dryPos = (dryPos + 1) % dryL.count
            }
        }
        lastStepTime = CFAbsoluteTimeGetCurrent() - t0
        emit(outL, outR, step)
        return true
    }
}
