import AppKit
import QuartzCore

private final class ThreadNotificationButton: NSButton {
    override var isFlipped: Bool { true }
    var rowColor: NSColor = .labelColor {
        didSet {
            contentTintColor = rowColor
            needsDisplay = true
        }
    }

    init(isOn: Bool, title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        setButtonType(.toggle)
        isBordered = false
        focusRingType = .none
        state = isOn ? .on : .off
        imagePosition = .imageOnly
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        rowColor.withAlphaComponent(state == .on ? 0.09 : 0.035).setFill()
        circle.fill()
        rowColor.withAlphaComponent(state == .on ? 0.13 : 0.2).setStroke()
        circle.lineWidth = 0.8
        circle.stroke()
        super.draw(dirtyRect)
    }

    func updateAppearance() {
        let symbolName = state == .on ? "bell" : "bell.slash"
        let description = state == .on ? "알림 켜짐" : "알림 꺼짐"
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        contentTintColor = rowColor
        setAccessibilityValue(state == .on ? "켜짐" : "꺼짐")
        toolTip = !isEnabled ? L10n.text("작업 상태 확인 불가")
            : state == .on ? "알림 켜짐 · 클릭하여 끄기" : "알림 꺼짐 · 클릭하여 켜기"
        needsDisplay = true
    }
}

/// A transparent overlay lets one synchronized sweep cross both the title and bell glyph.
private final class ThreadShimmerOverlay: NSView {
    override var isFlipped: Bool { true }

    let gradient = CAGradientLayer()
    private let maskLayer = CALayer()
    private let textMask = CATextLayer()
    private let bellMask = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = maskLayer
        maskLayer.addSublayer(textMask)
        maskLayer.addSublayer(bellMask)
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(title: String, titleFrame: NSRect, symbol: NSImage?, symbolFrame: NSRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        maskLayer.frame = bounds
        textMask.frame = titleFrame
        textMask.contentsScale = scale
        textMask.string = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white
        ])
        textMask.truncationMode = .end
        textMask.alignmentMode = .left
        bellMask.contentsScale = scale
        bellMask.contentsGravity = .resizeAspect
        if let symbol {
            var proposedRect = CGRect(origin: .zero, size: symbol.size)
            bellMask.contents = symbol.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        } else {
            bellMask.contents = nil
        }
        bellMask.frame = symbolFrame
        CATransaction.commit()
    }
}

/// A native button keeps keyboard activation and VoiceOver while drawing the compact row.
final class ThreadActivityButton: NSButton {
    private var activity: ThreadActivity
    private let shimmerOverlay = ThreadShimmerOverlay(frame: .zero)
    private let notificationButton: ThreadNotificationButton
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private let onOpened: (ThreadActivity) -> Void

    init(activity: ThreadActivity, frame: NSRect, onOpened: @escaping (ThreadActivity) -> Void = { _ in }) {
        self.activity = activity
        self.onOpened = onOpened
        notificationButton = ThreadNotificationButton(
            isOn: ThreadNotificationPreferences.shared.enabled(activity),
            title: "\(activity.title) 알림")
        super.init(frame: frame)
        isBordered = false
        title = ""
        target = self
        action = #selector(openThread)
        setAccessibilityLabel("\(activity.statusLabel), \(activity.title)")
        toolTip = activity.statusLabel
        wantsLayer = true
        notificationButton.isEnabled = ThreadNotificationPreferences.scope(for: activity) != nil
        notificationButton.rowColor = activity.isRunning ? .secondaryLabelColor : .labelColor
        notificationButton.updateAppearance()
        notificationButton.target = self
        notificationButton.action = #selector(toggleNotifications)
        addSubview(notificationButton)
        addSubview(shimmerOverlay)
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
        // A menu can reposition/recreate its tracking area without sending mouseExited.
        refreshHover()
    }

    func refreshHover() {
        let hovered = pointerIsInside()
        if isHovered != hovered { isHovered = hovered; needsDisplay = true }
    }

    private func pointerIsInside() -> Bool {
        guard let window else { return false }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return bounds.contains(point) && visibleRect.contains(point)
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
        isHovered = false
        needsDisplay = true
        updateShimmer()
    }

    func update(activity: ThreadActivity) {
        let previous = self.activity
        let notificationState: NSControl.StateValue = ThreadNotificationPreferences.shared.enabled(activity) ? .on : .off
        let canToggleNotification = ThreadNotificationPreferences.scope(for: activity) != nil
        let rowColor: NSColor = activity.isRunning ? .secondaryLabelColor : .labelColor
        let notificationAppearanceChanged = notificationButton.state != notificationState
            || !notificationButton.rowColor.isEqual(rowColor)
            || notificationButton.isEnabled != canToggleNotification
        let presentationChanged = previous.title != activity.title
            || previous.statusLabel != activity.statusLabel
            || previous.isRunning != activity.isRunning
            || previous.stateConfirmed != activity.stateConfirmed
        self.activity = activity
        if notificationAppearanceChanged {
            notificationButton.isEnabled = canToggleNotification
            notificationButton.state = notificationState
            notificationButton.rowColor = rowColor
            notificationButton.updateAppearance()
            needsLayout = true
        }
        if previous.title != activity.title {
            notificationButton.setAccessibilityLabel("\(activity.title) 알림")
        }
        guard presentationChanged else { return }
        setAccessibilityLabel("\(activity.statusLabel), \(activity.title)")
        toolTip = activity.statusLabel
        needsLayout = true
        needsDisplay = true
        if previous.isRunning != activity.isRunning || previous.stateConfirmed != activity.stateConfirmed {
            updateShimmer()
        }
    }

    private func updateShimmer() {
        shimmerOverlay.gradient.removeAllAnimations()
        shimmerOverlay.isHidden = !activity.stateConfirmed || !activity.isRunning || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard window != nil, !shimmerOverlay.isHidden else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.35, -0.18, 0]
        animation.toValue = [1, 1.18, 1.35]
        animation.duration = 2.2
        animation.repeatCount = .infinity
        shimmerOverlay.gradient.add(animation, forKey: "thinking")
    }

    override func layout() {
        super.layout()
        notificationButton.frame = NSRect(x: bounds.width - 30, y: 6, width: 22, height: 22)
        shimmerOverlay.frame = bounds
        let titleFrame = NSRect(x: 36, y: 10, width: max(0, bounds.width - 78), height: 18)
        let symbolSize = notificationButton.image?.size ?? NSSize(width: 11, height: 11)
        let symbolFrame = NSRect(
            x: notificationButton.frame.midX - symbolSize.width / 2,
            y: notificationButton.frame.midY - symbolSize.height / 2,
            width: symbolSize.width,
            height: symbolSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmerOverlay.configure(
            title: activity.title,
            titleFrame: titleFrame,
            symbol: notificationButton.image,
            symbolFrame: symbolFrame,
            scale: window?.backingScaleFactor ?? 2)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        if (isHovered || isHighlighted) && pointerIsInside() {
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
        inset.translate(x: 6, y: 2)
        arrow.transform(using: inset)
        arrow.lineWidth = 1.1
        arrow.lineJoinStyle = .round
        arrow.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (activity.title as NSString).draw(in: NSRect(x: 36, y: 10, width: max(0, bounds.width - 78), height: 18), withAttributes: [
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

    @objc private func toggleNotifications() {
        ThreadNotificationPreferences.shared.setEnabled(notificationButton.state == .on, for: activity)
        notificationButton.updateAppearance()
        needsLayout = true
    }

    var testHookHovered: Bool { isHovered }
    func testHookSetHovered(_ value: Bool) { isHovered = value }
}

final class ThreadActivityView: NSView {
    override var isFlipped: Bool { true }
    private let scroll = NSScrollView()
    private let document = ActivityDocumentView()
    private var buttons: [String: ThreadActivityButton] = [:]
    private var orderedIDs: [String] = []
    private let onOpened: (ThreadActivity) -> Void

    init(activities: [ThreadActivity], onOpened: @escaping (ThreadActivity) -> Void = { _ in }) {
        self.onOpened = onOpened
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(scroll)
        connectionLabel.font = .systemFont(ofSize: 11)
        connectionLabel.textColor = .secondaryLabelColor
        addSubview(connectionLabel)
        update(activities: activities)
    }

    required init?(coder: NSCoder) { nil }

    private let connectionLabel = NSTextField(labelWithString: "")

    /// Keep the menu stable while tracking, but shrink promptly when rows are removed.
    func update(activities: [ThreadActivity], preserveHeight: Bool = false, connected: Bool = true, incompatible: Bool = false) {
        let allConfirmed = connected && !incompatible && activities.allSatisfy(\.stateConfirmed)
        let statusChanged = connectionLabel.isHidden != allConfirmed
        let connectionStatus = incompatible ? L10n.text("Codex 연결 형식 미지원 · 앱 업데이트를 확인하세요")
            : L10n.text("작업 상태 연결 복구 중 · 마지막 확인 정보")
        let statusTextChanged = connectionLabel.stringValue != connectionStatus
        if statusChanged { connectionLabel.isHidden = allConfirmed }
        if statusTextChanged { connectionLabel.stringValue = connectionStatus }
        let statusHeight: CGFloat = allConfirmed ? 0 : 22
        let incoming = Set(activities.map(\.id))
        let previousOrder = orderedIDs
        let animate = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for id in Array(buttons.keys) where !incoming.contains(id) {
            guard let button = buttons.removeValue(forKey: id) else { continue }
            button.isEnabled = false
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    button.animator().alphaValue = 0
                } completionHandler: { button.removeFromSuperview() }
            } else { button.removeFromSuperview() }
        }
        if preserveHeight {
            orderedIDs = orderedIDs.filter { incoming.contains($0) }
            orderedIDs += activities.map(\.id).filter { !orderedIDs.contains($0) }
        } else { orderedIDs = activities.map(\.id) }
        let orderChanged = orderedIDs != previousOrder
        for activity in activities {
            if let button = buttons[activity.id] { button.update(activity: activity) }
            else {
                let button = ThreadActivityButton(activity: activity, frame: .zero, onOpened: onOpened)
                buttons[activity.id] = button
                document.addSubview(button)
                if animate {
                    button.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.15
                        button.animator().alphaValue = 1
                    }
                }
            }
        }
        var viewSizeChanged = false
        let rowsHeight: CGFloat = activities.isEmpty ? 0 : 8 + CGFloat(min(activities.count, 5)) * 34
        let targetSize = NSSize(width: 300, height: rowsHeight + statusHeight)
        let shouldShrinkWhileTracking = preserveHeight && targetSize.height < frame.height
        if activities.isEmpty || !preserveHeight || bounds.height == 0 || statusChanged || shouldShrinkWhileTracking {
            if frame.size != targetSize {
                setFrameSize(targetSize)
                viewSizeChanged = true
            }
        }
        let connectionFrame = NSRect(x: 12, y: 3, width: 276, height: 18)
        if connectionLabel.frame != connectionFrame { connectionLabel.frame = connectionFrame }
        let scrollFrame = NSRect(x: 12, y: 4 + statusHeight, width: 276,
                                 height: max(0, bounds.height - 8 - statusHeight))
        let scrollFrameChanged = scroll.frame != scrollFrame
        if scrollFrameChanged { scroll.frame = scrollFrame }
        let documentSize = NSSize(width: 276, height: max(scroll.bounds.height, CGFloat(orderedIDs.count) * 34))
        let documentSizeChanged = document.frame.size != documentSize
        if documentSizeChanged { document.setFrameSize(documentSize) }
        let needsScroller = CGFloat(orderedIDs.count) * 34 > scroll.bounds.height
        let scrollerChanged = scroll.hasVerticalScroller != needsScroller
        if scrollerChanged { scroll.hasVerticalScroller = needsScroller }
        for (index, id) in orderedIDs.enumerated() {
            let targetFrame = NSRect(x: 0, y: CGFloat(index) * 34, width: 276, height: 34)
            if let button = buttons[id], button.frame != targetFrame { button.frame = targetFrame }
        }
        let currentOrigin = scroll.contentView.bounds.origin
        let targetOrigin = NSPoint(x: 0, y: min(currentOrigin.y,
            max(0, document.bounds.height - scroll.contentView.bounds.height)))
        let scrollPositionChanged = currentOrigin != targetOrigin
        if scrollPositionChanged { scroll.contentView.scroll(to: targetOrigin) }
        if scrollFrameChanged || documentSizeChanged || scrollerChanged || scrollPositionChanged {
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if statusChanged || statusTextChanged || orderChanged || viewSizeChanged { needsDisplay = true }
        refreshHover()
    }

    func refreshHover() {
        for case let scroll as NSScrollView in subviews {
            for case let button as ThreadActivityButton in scroll.documentView?.subviews ?? [] {
                button.refreshHover()
            }
        }
    }
}

private final class ActivityDocumentView: NSView {
    override var isFlipped: Bool { true }
}
