// The menu bar icon: the Vocalizer logo simplified for 18 pt (a ring, a tiny squiggle in, a clean wave out),
// drawn as a template image so macOS tints it like any system icon. On: a filled disc with the wave cut out.
// Off: just the ring and the wave.

import AppKit

enum MenuIcon {
    private static var cache: [Bool: NSImage] = [:]

    static func image(on: Bool) -> NSImage {
        if let img = cache[on] { return img }
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            let wave = waveform(in: rect)
            if on {
                NSColor.black.setFill()
                ring.fill()
                // Knock the waveform out of the disc.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                wave.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                NSColor.black.setStroke()
                ring.lineWidth = 1.2
                ring.stroke()
                wave.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = on ? "Vocalizer, on" : "Vocalizer, off"
        cache[on] = img
        return img
    }

    /// A tiny squiggle at the very start (the messy sound going in), then a big clean wave (the voice
    /// coming out). At 18 pt the clean wave has to dominate or the icon reads as noise.
    private static func waveform(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = 1.3
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        let mid = r.midY
        // In: a short, small zigzag.
        p.move(to: NSPoint(x: 3.3, y: mid + 0.2))
        p.line(to: NSPoint(x: 4.3, y: mid + 1.4))
        p.line(to: NSPoint(x: 5.3, y: mid - 1.4))
        p.line(to: NSPoint(x: 6.3, y: mid))
        // Out: 1.5 smooth periods of a sine wave, taller than the zigzag.
        let start: CGFloat = 6.3, end: CGFloat = 14.7, amp: CGFloat = 3.0
        let steps = 48
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = start + (end - start) * t
            let y = mid + amp * sin(t * 2 * .pi * 1.5)
            p.line(to: NSPoint(x: x, y: y))
        }
        return p
    }
}
