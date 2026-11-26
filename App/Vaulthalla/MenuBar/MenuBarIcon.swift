import AppKit
import VHNodes

/// The menu bar item's image (docs/mac-experience.md §2): the Vaulthalla mark, with the fleet's state told by shape
/// and never by colour. A template image, so macOS draws it for a light or dark menu bar, a tinted one, and for
/// people who cannot tell red from green.
///
/// The app icon's illustration can't be read at this size, so the mark is a shield with a V: the vault, and the name.
nonisolated enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    @MainActor private static var cache: [FleetStatus.Level: NSImage] = [:]

    @MainActor static func image(for level: FleetStatus.Level) -> NSImage {
        if let cached = cache[level] { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            draw(level)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description(of: level)
        cache[level] = image
        return image
    }

    static func description(of level: FleetStatus.Level) -> String {
        switch level {
        case .notReporting: "Vaulthalla, not reporting"
        case .quiet: "Vaulthalla, all quiet"
        case .warnings: "Vaulthalla, warnings"
        case .attention: "Vaulthalla, needs attention"
        }
    }

    /// Draws in an 18-point box, origin bottom left. Template images use only alpha: black is "ink".
    private static func draw(_ level: FleetStatus.Level) {
        let ink = NSColor.black.withAlphaComponent(level == .notReporting ? 0.45 : 1)
        ink.setStroke()
        ink.setFill()

        // The shield: flat top, straight sides, a pointed base.
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: 3.25, y: 15.25))
        shield.line(to: NSPoint(x: 14.75, y: 15.25))
        shield.line(to: NSPoint(x: 14.75, y: 8.6))
        shield.curve(to: NSPoint(x: 9, y: 1.9), controlPoint1: NSPoint(x: 14.75, y: 5.4),
                     controlPoint2: NSPoint(x: 12.3, y: 3.1))
        shield.curve(to: NSPoint(x: 3.25, y: 8.6), controlPoint1: NSPoint(x: 5.7, y: 3.1),
                     controlPoint2: NSPoint(x: 3.25, y: 5.4))
        shield.close()
        shield.lineWidth = 1.5
        shield.lineJoinStyle = .round
        shield.stroke()

        // The V.
        let letter = NSBezierPath()
        letter.move(to: NSPoint(x: 6.2, y: 12))
        letter.line(to: NSPoint(x: 9, y: 6.1))
        letter.line(to: NSPoint(x: 11.8, y: 12))
        letter.lineWidth = 1.7
        letter.lineCapStyle = .round
        letter.lineJoinStyle = .round
        letter.stroke()

        // The badge, top right: filled for "needs attention", hollow for "warnings only". A gap is cut around it
        // first so it reads against the shield.
        guard level == .attention || level == .warnings else { return }
        let center = NSPoint(x: 14.1, y: 14.1)
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: center.x - 4.9, y: center.y - 4.9, width: 9.8, height: 9.8))
            context.restoreGState()
        }
        if level == .attention {
            NSBezierPath(ovalIn: NSRect(x: center.x - 3.6, y: center.y - 3.6, width: 7.2, height: 7.2)).fill()
        } else {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 2.9, y: center.y - 2.9, width: 5.8, height: 5.8))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}
