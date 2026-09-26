import AppKit

enum CodexStatusIcon {
    static func plusCodexImage(size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: AIProvider.codex.resource, withExtension: "svg"),
              let source = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: NSRect(x: 0.5, y: 0.5, width: size * 0.76, height: size * 0.76))
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceIn)

            let center = NSPoint(x: size * 0.79, y: size * 0.79)
            let reach = size * 0.13
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: center.x - reach, y: center.y))
            plus.line(to: NSPoint(x: center.x + reach, y: center.y))
            plus.move(to: NSPoint(x: center.x, y: center.y - reach))
            plus.line(to: NSPoint(x: center.x, y: center.y + reach))
            plus.lineCapStyle = .round
            // Separate the small plus from the knot at menu-bar size.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setStroke()
            plus.lineWidth = size * 0.22
            plus.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.setStroke()
            plus.lineWidth = size * 0.11
            plus.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func image(size: CGFloat, offline: Bool, provider: AIProvider = .codex) -> NSImage? {
        guard let url = Bundle.main.url(forResource: provider.resource, withExtension: "svg"),
              let source = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect)
            (offline ? NSColor.systemGray : NSColor.labelColor).setFill()
            rect.fill(using: .sourceIn)
            if offline {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: size * 0.12, y: size * 0.12))
                slash.line(to: NSPoint(x: size * 0.88, y: size * 0.88))
                slash.lineCapStyle = .round
                // Clear a narrow channel so the slash remains legible over the knot.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.clear.setStroke()
                slash.lineWidth = size * 0.18
                slash.stroke()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.systemGray.setStroke()
                slash.lineWidth = size * 0.085
                slash.stroke()
            }
            return true
        }
        image.isTemplate = !offline
        return image
    }
}
