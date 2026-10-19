// Builds the macOS app icon from Resources/brand/logo.png (the neon waveform logo).
//   swift tools/make-icon.swift Resources/brand/logo.png out.png [size]
// macOS icon grid: an 824/1024 rounded square, centred, with the logo cropped to its middle.
import AppKit

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let size = args.count > 3 ? Int(args[3])! : 1024
let s = CGFloat(size)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let inset = s * 100 / 1024, side = s * 824 / 1024
let rect = CGRect(x: inset, y: inset, width: side, height: side)
let path = CGPath(roundedRect: rect, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
// Soft drop shadow like Apple's icons.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.05, green: 0.02, blue: 0.09, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
// Logo, cropped so the ring fills most of the tile.
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let crop = CGRect(x: 120, y: 120, width: 784, height: 784)
let cropped = src.cropping(to: crop)!
ctx.interpolationQuality = .high
ctx.draw(cropped, in: rect)
ctx.restoreGState()
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
