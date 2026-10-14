// The DillyDally mark: two overlapping screens, the front one a mirror with a
// shine on it. Drawn in code so the menu-bar icon and the app icon (icon.swift)
// come from one place.

import AppKit

enum Glyph {
    private static let shine: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6.4, y: 15.6))
        path.addLine(to: CGPoint(x: 9.6, y: 11.6))
        path.move(to: CGPoint(x: 10.2, y: 16))
        path.addLine(to: CGPoint(x: 12, y: 13.8))
        return path
    }()

    private static func screen(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
               cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Draw into `rect` in the current graphics context. The design sits on a
    /// 24-unit grid with y pointing down. Outlined when idle, solid while
    /// casting; `dot` adds a spot for "something needs a look".
    static func draw(in rect: CGRect, filled: Bool, dot: Bool = false, color: NSColor = .black) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let everything = CGRect(x: -1, y: -1, width: 26, height: 26)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / 24, y: -rect.height / 24)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // The back screen, with a gap where the front one covers it.
        context.saveGState()
        context.addRect(everything)
        context.addPath(screen(1.4, 6.9, 16.2, 13.2, 3))
        context.clip(using: .evenOdd)
        if filled {
            context.addPath(screen(7.25, 2.75, 15, 11.5, 2.6))
            context.fillPath()
        } else {
            context.addPath(screen(8, 3.5, 13.5, 10, 2))
            context.strokePath()
        }
        context.restoreGState()

        if filled {
            // The shine is cut out of the solid front screen.
            context.saveGState()
            context.addRect(everything)
            context.addPath(shine.copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 1))
            context.clip(using: .evenOdd)
            context.addPath(screen(2, 7.5, 15, 12, 2.6))
            context.fillPath()
            context.restoreGState()
        } else {
            context.addPath(screen(2.75, 8.25, 13.5, 10.5, 2))
            context.addPath(shine)
            context.strokePath()
        }
        if dot {
            context.fillEllipse(in: CGRect(x: 18.4, y: 16.4, width: 5.2, height: 5.2))
        }
        context.restoreGState()
    }

    /// A template image for the menu bar.
    static func menuBarImage(filled: Bool, dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            draw(in: CGRect(x: 1, y: 0, width: 18, height: 18), filled: filled, dot: dot)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DillyDally"
        return image
    }
}
