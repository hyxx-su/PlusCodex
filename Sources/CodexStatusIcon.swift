import AppKit

enum CodexStatusIcon {
    static func image(size: CGFloat, offline: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Codex", withExtension: "svg"),
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
