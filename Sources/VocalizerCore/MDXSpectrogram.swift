// MDX-Net (UVR) spectrogram front end, ported from vocalizer/extension/src/core/mdx.js.
// Matches torch.stft / torch.istft (center=True, reflect padding, periodic Hann).
// Model: UVR MDX-Net vocals (n_fft 7680, hop 1024, dim_f 3072, compensate 1.043).
// The network is convolutional in time, so any window of `frames` (a multiple of 32) works.

import Accelerate

public enum MDX {
    public static let sampleRate = 44_100.0
    public static let nFFT = 7680
    public static let hop = 1024
    public static let dimF = 3072
    public static let compensate: Float = 1.043
    /// Samples discarded at each window edge (STFT edge effects).
    public static let trim = nFFT / 2

    /// Waveform samples covered by a window of `frames` STFT frames.
    public static func chunk(frames: Int) -> Int { hop * (frames - 1) }
}

/// Strided view of a [4, dimF, frames] spectrogram (Core ML outputs may be padded).
public struct SpecView {
    public var base: UnsafePointer<Float>
    public var strideC: Int, strideF: Int, strideT: Int
    public init(base: UnsafePointer<Float>, strideC: Int, strideF: Int, strideT: Int) {
        self.base = base; self.strideC = strideC; self.strideF = strideF; self.strideT = strideT
    }
}

public final class MDXSpectrogram {
    public let frames: Int
    public let chunk: Int
    private let n = MDX.nFFT
    private let window: UnsafeMutablePointer<Float>
    private let invEnv: UnsafeMutablePointer<Float>
    private let padL: UnsafeMutablePointer<Float>, padR: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>
    private let oRe: UnsafeMutablePointer<Float>, oIm: UnsafeMutablePointer<Float>
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    public init(frames: Int) {
        precondition(frames % 32 == 0, "MDX windows must be a multiple of 32 frames")
        self.frames = frames
        chunk = MDX.chunk(frames: frames)
        let n = MDX.nFFT
        func buf(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        window = buf(n)
        for i in 0..<n { window[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n)) }
        padL = buf(chunk + n); padR = buf(chunk + n)
        re = buf(n); im = buf(n); oRe = buf(n); oIm = buf(n)
        invEnv = buf(chunk)
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(n), .INVERSE)!

        // istft normalisation: overlap-added squared window over the centre-padded signal.
        var env = [Float](repeating: 0, count: chunk + n)
        for t in 0..<frames {
            for i in 0..<n { env[t * MDX.hop + i] += window[i] * window[i] }
        }
        for i in 0..<chunk {
            let e = env[i + MDX.trim]
            invEnv[i] = e > 1e-11 ? 1 / e : 0
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(inverse)
        vDSP_DFT_DestroySetup(forward)
        for p in [window, invEnv, padL, padR, re, im, oRe, oIm] { p.deallocate() }
    }

    /// Stereo waveform (2 x chunk) -> model input [4, dimF, frames] (contiguous): L.re, L.im, R.re, R.im.
    /// Zeroes the 3 lowest bins like UVR.
    public func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let trim = MDX.trim, dimF = MDX.dimF, n = self.n
        for (x, p) in [(left, padL), (right, padR)] {
            (p + trim).update(from: x, count: chunk)
            for i in 0..<trim {
                p[i] = x[trim - i]
                p[trim + chunk + i] = x[chunk - 2 - i]
            }
        }
        let plane = dimF * frames
        for t in 0..<frames {
            let off = t * MDX.hop
            // Pack both real channels into one complex DFT: z = L + iR.
            vDSP_vmul(padL + off, 1, window, 1, re, 1, vDSP_Length(n))
            vDSP_vmul(padR + off, 1, window, 1, im, 1, vDSP_Length(n))
            vDSP_DFT_Execute(forward, re, im, oRe, oIm)
            for f in 0..<dimF {
                let idx = f * frames + t
                if f < 3 {
                    out[idx] = 0; out[plane + idx] = 0; out[2 * plane + idx] = 0; out[3 * plane + idx] = 0
                    continue
                }
                let g = n - f
                let zr = oRe[f], zi = oIm[f], wr = oRe[g], wi = oIm[g]
                out[idx] = (zr + wr) / 2 // L re
                out[plane + idx] = (zi - wi) / 2 // L im
                out[2 * plane + idx] = (zi + wi) / 2 // R re
                out[3 * plane + idx] = -(zr - wr) / 2 // R im
            }
        }
    }

    /// Model output [4, dimF, frames] -> stereo waveform (2 x chunk), torch.istft(center=True).
    public func synthesize(_ spec: SpecView, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let n = self.n, half = n / 2
        var scale = 1 / Float(n)
        padL.update(repeating: 0, count: chunk + n)
        padR.update(repeating: 0, count: chunk + n)
        let b = spec.base, sc = spec.strideC, sf = spec.strideF
        for t in 0..<frames {
            vDSP_vclr(re, 1, vDSP_Length(n))
            vDSP_vclr(im, 1, vDSP_Length(n))
            let bt = b + t * spec.strideT
            // Z[k] = L[k] + i·R[k] for k <= N/2, conj-mirrored above so the inverse gives l + i·r.
            for f in 0..<MDX.dimF {
                let p = bt + f * sf
                let lr = p[0]
                let li = f == 0 ? 0 : p[sc]
                let rr = p[2 * sc]
                let ri = f == 0 ? 0 : p[3 * sc]
                re[f] = lr - ri
                im[f] = li + rr
                if f > 0 && f < half {
                    re[n - f] = lr + ri
                    im[n - f] = -li + rr
                }
            }
            vDSP_DFT_Execute(inverse, re, im, oRe, oIm)
            vDSP_vsmul(oRe, 1, &scale, oRe, 1, vDSP_Length(n))
            vDSP_vsmul(oIm, 1, &scale, oIm, 1, vDSP_Length(n))
            let off = t * MDX.hop
            vDSP_vma(oRe, 1, window, 1, padL + off, 1, padL + off, 1, vDSP_Length(n))
            vDSP_vma(oIm, 1, window, 1, padR + off, 1, padR + off, 1, vDSP_Length(n))
        }
        vDSP_vmul(padL + MDX.trim, 1, invEnv, 1, left, 1, vDSP_Length(chunk))
        vDSP_vmul(padR + MDX.trim, 1, invEnv, 1, right, 1, vDSP_Length(chunk))
    }
}
