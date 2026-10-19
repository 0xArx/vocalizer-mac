// The menu bar icon: the Vocalizer logo (a ring with messy sound in, the filter bars, a clean wave out),
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

    /// Messy wave in on the left, three bars, one clean wave out on the right.
    private static func waveform(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = 1.05
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        let mid = r.midY
        // In: an uneven wiggle.
        let inPts: [(CGFloat, CGFloat)] = [(3.8, 0.2), (4.7, 2.0), (5.6, -1.7), (6.4, 0.5)]
        p.move(to: NSPoint(x: inPts[0].0, y: mid + inPts[0].1))
        for (x, dy) in inPts.dropFirst() { p.line(to: NSPoint(x: x, y: mid + dy)) }
        // The filter: three bars, tallest in the middle.
        for (x, h) in [(7.7, 5.0), (9.3, 8.6), (10.9, 4.4)] as [(CGFloat, CGFloat)] {
            p.move(to: NSPoint(x: x, y: mid - h / 2))
            p.line(to: NSPoint(x: x, y: mid + h / 2))
        }
        // Out: one clean wave.
        p.move(to: NSPoint(x: 12.2, y: mid))
        p.curve(to: NSPoint(x: 13.3, y: mid), controlPoint1: NSPoint(x: 12.5, y: mid + 1.7), controlPoint2: NSPoint(x: 13.0, y: mid + 1.7))
        p.curve(to: NSPoint(x: 14.4, y: mid), controlPoint1: NSPoint(x: 13.6, y: mid - 1.7), controlPoint2: NSPoint(x: 14.1, y: mid - 1.7))
        return p
    }
}
