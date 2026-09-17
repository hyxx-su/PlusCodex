import AppKit
import QuartzCore

/// A native button keeps keyboard activation and VoiceOver while drawing the compact row.
final class ThreadActivityButton: NSButton {
    private let activity: ThreadActivity
    private let shimmer = CAGradientLayer()
    private let textMask = CATextLayer()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private let onOpened: (ThreadActivity) -> Void

    init(activity: ThreadActivity, frame: NSRect, onOpened: @escaping (ThreadActivity) -> Void = { _ in }) {
        self.activity = activity
        self.onOpened = onOpened
        super.init(frame: frame)
        isBordered = false
        title = ""
        target = self
        action = #selector(openThread)
        setAccessibilityLabel("\(activity.isRunning ? "작업 중" : "완료 · 미확인"), \(activity.title)")
        wantsLayer = true
        shimmer.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        shimmer.locations = [0, 0.5, 1]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.mask = textMask
        layer?.addSublayer(shimmer)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shimmer.removeAllAnimations()
        shimmer.isHidden = !activity.isRunning || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard window != nil, !shimmer.isHidden else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.35, -0.18, 0]
        animation.toValue = [1, 1.18, 1.35]
        animation.duration = 2.2
        animation.repeatCount = .infinity
        shimmer.add(animation, forKey: "thinking")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.frame = NSRect(x: 36, y: 8, width: bounds.width - 50, height: 18)
        textMask.frame = shimmer.bounds
        textMask.contentsScale = window?.backingScaleFactor ?? 2
        textMask.string = NSAttributedString(string: activity.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white
        ])
        textMask.truncationMode = .end
        textMask.alignmentMode = .left
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
        }
        let color: NSColor = activity.isRunning ? .secondaryLabelColor : .labelColor
        color.setStroke()
        // Rounded outline arrow matching the supplied navigation icon.
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 9.4, y: 10.5))
        arrow.line(to: NSPoint(x: 18.3, y: 13.7))
        arrow.curve(to: NSPoint(x: 18.4, y: 15), controlPoint1: NSPoint(x: 19.2, y: 14), controlPoint2: NSPoint(x: 19.2, y: 14.6))
        arrow.line(to: NSPoint(x: 14.8, y: 16.7))
        arrow.line(to: NSPoint(x: 13.1, y: 20.3))
        arrow.curve(to: NSPoint(x: 11.8, y: 20.2), controlPoint1: NSPoint(x: 12.7, y: 21.1), controlPoint2: NSPoint(x: 12.1, y: 21.1))
        arrow.line(to: NSPoint(x: 8.6, y: 11.3))
        arrow.curve(to: NSPoint(x: 9.4, y: 10.5), controlPoint1: NSPoint(x: 8.3, y: 10.5), controlPoint2: NSPoint(x: 8.6, y: 10.2))
        arrow.close()
        var inset = AffineTransform()
        inset.translate(x: 6, y: 0)
        arrow.transform(using: inset)
        arrow.lineWidth = 1.1
        arrow.lineJoinStyle = .round
        arrow.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (activity.title as NSString).draw(in: NSRect(x: 36, y: 8, width: bounds.width - 50, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    @objc private func openThread() {
        guard let url = activity.url else { return }
        var ancestor: NSView? = self
        while let view = ancestor {
            if let menu = view.enclosingMenuItem?.menu { menu.cancelTracking(); break }
            ancestor = view.superview
        }
        if NSWorkspace.shared.open(url) { onOpened(activity) }
    }
}

final class ThreadActivityView: NSView {
    override var isFlipped: Bool { true }

    init(activities: [ThreadActivity], onOpened: @escaping (ThreadActivity) -> Void = { _ in }) {
        let count = max(1, activities.count)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: activities.isEmpty ? 0 : 8 + CGFloat(min(count, 5)) * 34))
        if !activities.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 12, y: 4, width: 276, height: CGFloat(min(count, 5)) * 34))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = count > 5
            scroll.scrollerStyle = .overlay
            let document = ActivityDocumentView(frame: NSRect(x: 0, y: 0, width: 276, height: CGFloat(count) * 34))
            for (index, activity) in activities.enumerated() {
                document.addSubview(ThreadActivityButton(activity: activity,
                    frame: NSRect(x: 0, y: CGFloat(index) * 34, width: 276, height: 34), onOpened: onOpened))
            }
            scroll.documentView = document
            addSubview(scroll)
        }
    }

    required init?(coder: NSCoder) { nil }
}

private final class ActivityDocumentView: NSView {
    override var isFlipped: Bool { true }
}
