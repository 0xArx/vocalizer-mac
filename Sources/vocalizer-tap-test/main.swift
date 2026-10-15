// CLI wrapper for LoopbackTest. Only captures audio if the terminal has System Audio Recording
// permission; otherwise use `open build/Vocalizer.app --args --selftest ...`.
//   vocalizer-tap-test <models dir> <audio file> <seconds> <live|balanced|quality> <out dir>

import Foundation
import VocalizerCore

let a = CommandLine.arguments
guard a.count >= 6 else { print("usage: vocalizer-tap-test <models> <file> <seconds> <mode> <outdir>"); exit(2) }
let models = URL(fileURLWithPath: a[1])
func modelURL(_ f: Int) -> URL {
    let c = models.appendingPathComponent("MDXVocals\(f).mlmodelc")
    return FileManager.default.fileExists(atPath: c.path) ? c : models.appendingPathComponent("MDXVocals\(f).mlpackage")
}
let engine = VocalizerEngine(modelURLs: [32: modelURL(32), 64: modelURL(64), 256: modelURL(256)])
do {
    try LoopbackTest.run(engine: engine, file: a[2], seconds: Double(a[3])!, mode: a[4],
                         outDir: URL(fileURLWithPath: a[5])) { print($0) }
} catch {
    print("loopback test failed: \(error)")
    exit(1)
}
