import AppKit

final class MenuBarTokenHelpScrollView: NSScrollView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        refreshRowHoverFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        refreshRowHoverFromPointer()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        updateRowHover(atDocumentPoint: nil)
        onHoverChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        updateRowHover(atDocumentPoint: documentView?.convert(event.locationInWindow, from: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshRowHoverFromPointer()
    }

    @objc private func clipBoundsChanged(_ notification: Notification) { refreshRowHoverFromPointer() }

    private func refreshRowHoverFromPointer() {
        guard let window, let document = documentView, !isHiddenOrHasHiddenAncestor else {
            updateRowHover(atDocumentPoint: nil)
            return
        }
        let point = document.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        updateRowHover(atDocumentPoint: point)
    }

    func updateRowHover(atDocumentPoint point: NSPoint?) {
        guard let document = documentView else { return }
        // Scrolling can skip row-level mouseExited events. Recompute every row from
        // one current pointer position, including rows clipped out of the viewport.
        let visiblePoint = point.flatMap { document.visibleRect.contains($0) ? $0 : nil }
        for row in document.subviews.compactMap({ $0 as? MenuBarTokenCopyRow }) {
            row.setHovered(visiblePoint.map { row.frame.contains($0) } ?? false)
        }
    }
}

private final class MenuBarTokenDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class MenuBarTokenCopyRow: NSButton {
    private let token: String
    private let copyToken: (String) -> Bool
    private let copyIcon = NSImageView()
    private var isHovered = false

    init(entry: MenuBarFormat.HelpEntry, width: CGFloat, copy: @escaping (String) -> Bool) {
        token = entry.token
        copyToken = copy
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        target = self
        action = #selector(copyClicked)
        identifier = NSUserInterfaceItemIdentifier("menuBarToken-copy-\(entry.token)")
        setAccessibilityLabel(L10n.text("복사: %@", entry.token))
        setAccessibilityHelp(entry.detail)

        let code = NSTextField(labelWithString: entry.token)
        code.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        // Leave room for AppKit's text-cell insets so the final % is not clipped.
        let codeWidth = ceil(code.intrinsicContentSize.width) + 6
        let pill = NSView(frame: NSRect(x: 0, y: 2, width: codeWidth + 10, height: 20))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.setAdaptiveBackgroundColor(NSColor.labelColor.adaptiveAlpha(0.035))
        code.frame = NSRect(x: 5, y: 2, width: codeWidth, height: 16)
        code.setAccessibilityElement(false)
        pill.addSubview(code)
        addSubview(pill)
        let detailX = pill.frame.maxX + 6
        let detailWidth = max(1, width - detailX - 20)
        let detail = NSTextField(wrappingLabelWithString: entry.detail)
        let detailFont = NSFont.systemFont(ofSize: 10)
        detail.font = detailFont
        // A narrow tooltip must wrap long translations instead of hiding their meaning.
        let textBounds = (entry.detail as NSString).boundingRect(
            with: NSSize(width: max(1, detailWidth - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: detailFont])
        let detailHeight = max(14, ceil(textBounds.height) + 2)
        setFrameSize(NSSize(width: width, height: max(24, detailHeight + 6)))
        pill.frame.origin.y = (bounds.height - pill.frame.height) / 2
        detail.frame = NSRect(x: detailX, y: (bounds.height - detailHeight) / 2,
                              width: detailWidth, height: detailHeight)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.setAccessibilityElement(false)
        addSubview(detail)
        copyIcon.frame = NSRect(x: width - 14, y: (bounds.height - 12) / 2, width: 12, height: 12)
        copyIcon.contentTintColor = .secondaryLabelColor
        copyIcon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyIcon.setAccessibilityElement(false)
        addSubview(copyIcon)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        setAdaptiveBackgroundColor(hovered ? NSColor.labelColor.adaptiveAlpha(0.04) : .clear)
    }

    @objc private func copyClicked() {
        guard copyToken(token) else { NSSound.beep(); return }
        copyIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        setAccessibilityValue(L10n.text("복사됨"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyIcon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            self?.setAccessibilityValue(nil)
        }
    }
}

/// Scrollable, copyable token reference for the provider's current usage windows.
final class MenuBarTokenHelpView: NSViewController {
    var onHoverChanged: ((Bool) -> Void)? {
        didSet { (view as? MenuBarTokenHelpScrollView)?.onHoverChanged = onHoverChanged }
    }

    init(quota: Quota?, copy: @escaping (String) -> Bool = {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString($0, forType: .string)
    }) {
        super.init(nibName: nil, bundle: nil)
        let width: CGFloat = 280
        let document = MenuBarTokenDocument(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        func label(_ value: String, y: CGFloat, bold: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: value)
            field.frame = NSRect(x: 8, y: y, width: width - 16, height: 16)
            field.font = .systemFont(ofSize: bold ? 10.5 : 9, weight: bold ? .semibold : .regular)
            field.textColor = bold ? .labelColor : .secondaryLabelColor
            document.addSubview(field)
            return field
        }
        var y: CGFloat = 8
        for (index, section) in MenuBarFormat.helpSections(quota: quota).enumerated() {
            if index > 0 {
                let line = NSBox(frame: NSRect(x: 8, y: y + 2, width: width - 16, height: 1))
                line.boxType = .separator
                document.addSubview(line)
                y += 10
            }
            let header = label(section.title, y: y, bold: true)
            header.frame.size.width = 150
            if index == 0 {
                let hint = label(L10n.text("클릭하여 복사"), y: y + 1)
                hint.frame = NSRect(x: width - 94, y: y + 1, width: 86, height: 16)
                hint.alignment = .right
            }
            y += 20
            for entry in section.entries {
                let row = MenuBarTokenCopyRow(entry: entry, width: width - 16, copy: copy)
                row.frame.origin = NSPoint(x: 8, y: y)
                document.addSubview(row)
                y += row.frame.height
            }
        }
        y += 6
        let note: String
        if quota == nil {
            note = L10n.text("아직 조회된 한도가 없습니다. 사용량을 조회하면 이 AI에서 쓸 수 있는 토큰을 안내합니다.")
        } else if quota?.windows.isEmpty == true {
            note = L10n.text("현재 계정은 표시할 사용량 한도를 제공하지 않습니다.")
        } else {
            note = L10n.text("문자·구분자 조합 가능 · 최대 80자\n빈칸: 아이콘만 표시 · 미제공 값: —")
        }
        let footer = label(note, y: y)
        footer.frame.size.height = 36
        y += 44
        document.setFrameSize(NSSize(width: width, height: y))
        let height = min(210, y)
        let scroll = MenuBarTokenHelpScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        view = scroll
        preferredContentSize = scroll.frame.size
    }

    required init?(coder: NSCoder) { nil }
}
