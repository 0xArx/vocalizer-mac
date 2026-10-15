// Core ML wrapper for one converted MDX window size (tools/convert.py -> MDXVocals<frames>.mlpackage).

import CoreML
import Foundation

public final class MDXModel {
    public let frames: Int
    private let model: MLModel
    /// Contiguous [1, 4, dimF, frames] input; write the spectrogram straight into `inputPointer`.
    public let input: MLMultiArray
    public let inputPointer: UnsafeMutablePointer<Float>
    private let provider: MLDictionaryFeatureProvider
    private let options = MLPredictionOptions()

    /// `url` may be an .mlpackage (compiled on the fly) or an already compiled .mlmodelc.
    public init(url: URL, frames: Int, computeUnits: MLComputeUnits = .all) throws {
        self.frames = frames
        let compiled = url.pathExtension == "mlmodelc" ? url : try MDXModel.cachedCompile(url)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiled, configuration: config)
        input = try MLMultiArray(shape: [1, 4, NSNumber(value: MDX.dimF), NSNumber(value: frames)], dataType: .float32)
        inputPointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
    }

    /// Compiles an .mlpackage once into ~/Library/Application Support/Vocalizer (keyed by size and date).
    static func cachedCompile(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.appendingPathComponent("Manifest.json").path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vocalizer")
        let dest = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(Int(stamp)).mlmodelc")
        if fm.fileExists(atPath: dest.path) { return dest }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = try MLModel.compileModel(at: url)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Runs the model on `input` and hands the (possibly strided) output to `body`.
    public func run<T>(_ body: (SpecView) throws -> T) throws -> T {
        let out = try model.prediction(from: provider, options: options)
        guard let arr = out.featureValue(for: "output")?.multiArrayValue else {
            throw NSError(domain: "MDXModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "model returned no output"])
        }
        let s = arr.strides.map(\.intValue)
        if arr.dataType == .float32 {
            return try arr.withUnsafeBufferPointer(ofType: Float.self) { p in
                try body(SpecView(base: p.baseAddress!, strideC: s[1], strideF: s[2], strideT: s[3]))
            }
        }
        // Float16 output: convert to a contiguous float32 copy first.
        let count = 4 * MDX.dimF * frames
        var tmp = [Float](repeating: 0, count: count)
        let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: s[0])
        for c in 0..<4 { for f in 0..<MDX.dimF { for t in 0..<frames {
            tmp[(c * MDX.dimF + f) * frames + t] = Float(p[c * s[1] + f * s[2] + t * s[3]])
        } } }
        return try tmp.withUnsafeBufferPointer { p in
            try body(SpecView(base: p.baseAddress!, strideC: MDX.dimF * frames, strideF: frames, strideT: 1))
        }
    }
}
