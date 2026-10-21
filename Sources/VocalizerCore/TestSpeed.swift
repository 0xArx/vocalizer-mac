// Test hook: VOCALIZER_TEST_SPEED=<factor> makes every model call that many times slower, from the first call on,
// as on a slower Mac. The load-time calibration and playback both see it, so the self-tuning can be checked
// for Macs slower than the one running the test.
import Foundation

enum TestSpeed {
    static let factor = max(1, Double(ProcessInfo.processInfo.environment["VOCALIZER_TEST_SPEED"] ?? "") ?? 1)

    /// Call after a model call that started at `start` (CFAbsoluteTime).
    static func stretch(since start: CFAbsoluteTime) {
        guard factor > 1 else { return }
        Thread.sleep(forTimeInterval: (factor - 1) * (CFAbsoluteTimeGetCurrent() - start))
    }
}
