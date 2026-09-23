import AppKit

private final class SoundPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SoundPopoverDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SoundPopoverLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        guard !stringValue.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor ?? .labelColor,
            .paragraphStyle: paragraph
        ]
        let size = (stringValue as NSString).size(withAttributes: attributes)
        (stringValue as NSString).draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2,
                                                  width: bounds.width, height: size.height),
                                       withAttributes: attributes)
    }
}

private final class SoundPopoverOptionButton: NSButton {
    private var pointerInside = false { didSet { updateBackground() } }

    init(frame: NSRect, title: String, selected: Bool) {
        super.init(frame: frame)
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityLabel(title)

        let label = SoundPopoverLabel(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 8, y: 0, width: max(0, frame.width - 34), height: frame.height)
        label.setAccessibilityElement(false)
        addSubview(label)

        if selected {
            let checkmark = NSImageView(frame: NSRect(x: frame.width - 21, y: (frame.height - 14) / 2,
                                                      width: 14, height: 14))
            checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            checkmark.contentTintColor = .secondaryLabelColor
            checkmark.setAccessibilityElement(false)
            addSubview(checkmark)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        super.mouseExited(with: event)
    }

    private func updateBackground() {
        layer?.backgroundColor = pointerInside
            ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
            : NSColor.clear.cgColor
    }
}

private final class SoundPopoverDeleteButton: NSButton {
    private var pointerInside = false {
        didSet {
            layer?.backgroundColor = pointerInside
                ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
                : NSColor.clear.cgColor
            contentTintColor = pointerInside ? .labelColor : .secondaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        super.mouseExited(with: event)
    }
}

/// The sound library uses the same anchored search-panel treatment as the
/// language picker, while keeping its file-management actions independent.
final class NotificationSoundPopover: NSObject, NSTextFieldDelegate {
    var onSelectDefault: (() -> Void)?
    var onSelectSaved: ((String) -> Void)?
    var onAdd: (() -> Void)?
    var onDelete: ((String) -> Void)?

    private let panel = SoundPopoverPanel(contentRect: .zero, styleMask: [.borderless],
                                          backing: .buffered, defer: false)
    private let contentWidth: CGFloat = 260
    private let rowHeight: CGFloat = 30
    private let maximumVisibleRows = 6
    private var savedSounds: [SavedNotificationSound] = []
    private var optionRows: [(view: NSView, title: String)] = []
    private weak var searchField: NSTextField?
    private weak var emptyState: NSTextField?
    private weak var document: SoundPopoverDocumentView?
    private weak var scrollView: NSScrollView?
    private weak var anchorButton: NSButton?
    private var eventMonitor: Any?
    private var listHeight: CGFloat = 0

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    var isVisible: Bool { panel.isVisible }

    func show(from button: NSButton, sounds: [SavedNotificationSound], selectedID: String?) {
        close()
        anchorButton = button
        savedSounds = sounds
        buildContent(selectedID: selectedID)
        guard let window = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        let size = panel.frame.size
        panel.setFrame(NSRect(x: screenRect.maxX - size.width,
                              y: screenRect.minY - size.height - 4,
                              width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installOutsideClickMonitor()
        if let searchField { panel.makeFirstResponder(searchField) }
    }

    func close() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        panel.orderOut(nil)
    }

    private func buildContent(selectedID: String?) {
        optionRows.removeAll()
        let visibleRows = min(savedSounds.count + 1, maximumVisibleRows)
        listHeight = rowHeight * CGFloat(visibleRows)
        let listBottom: CGFloat = 56
        let headerHeight: CGFloat = 45
        let contentHeight = headerHeight + 8 + listHeight + listBottom
        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.cornerRadius = 13
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        content.layer?.masksToBounds = true

        let searchIcon = NSImageView(frame: NSRect(x: 13, y: contentHeight - 30, width: 15, height: 15))
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        content.addSubview(searchIcon)

        let search = NSTextField(frame: NSRect(x: 35, y: contentHeight - 38,
                                               width: contentWidth - 50, height: 24))
        search.placeholderString = L10n.text("알림 소리 검색")
        search.font = .systemFont(ofSize: 12.5)
        search.isBezeled = false
        search.isEditable = true
        search.isSelectable = true
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        search.setAccessibilityLabel(L10n.text("알림 소리 검색"))
        content.addSubview(search)
        searchField = search

        for y in [contentHeight - headerHeight, listBottom - 8] {
            let separator = NSBox(frame: NSRect(x: 10, y: y, width: contentWidth - 20, height: 1))
            separator.boxType = .separator
            content.addSubview(separator)
        }

        let scroll = NSScrollView(frame: NSRect(x: 4, y: listBottom,
                                                width: contentWidth - 8, height: listHeight))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = savedSounds.count + 1 > maximumVisibleRows
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.usesPredominantAxisScrolling = true
        let documentWidth = contentWidth - 8
        let documentHeight = rowHeight * CGFloat(savedSounds.count + 1)
        let document = SoundPopoverDocumentView(frame: NSRect(x: 0, y: 0,
                                                               width: documentWidth,
                                                               height: documentHeight))
        let rowWidth = documentWidth - 16
        addOption(title: L10n.text("기본 알림음"), index: -1,
                  selected: selectedID == nil, document: document, rowWidth: rowWidth)
        for (index, sound) in savedSounds.enumerated() {
            addOption(title: sound.displayTitle, index: index,
                      selected: selectedID == sound.id, document: document, rowWidth: rowWidth)
        }
        let empty = NSTextField(labelWithString: L10n.text("결과를 찾을 수 없습니다"))
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.frame = NSRect(x: 0, y: (listHeight - 24) / 2,
                             width: documentWidth, height: 24)
        empty.isHidden = true
        document.addSubview(empty)
        emptyState = empty
        scroll.documentView = document
        content.addSubview(scroll)
        scrollView = scroll
        self.document = document

        let add = SoundPopoverOptionButton(frame: NSRect(x: 12, y: 8,
                                                          width: contentWidth - 24, height: rowHeight),
                                            title: L10n.text("소리 추가…"), selected: false)
        add.target = self
        add.action = #selector(addSound(_:))
        content.addSubview(add)

        let contentSize = content.frame.size
        panel.contentView = content
        panel.setContentSize(contentSize)
        content.frame = NSRect(origin: .zero, size: contentSize)
        filterOptions(search)
    }

    private func addOption(title: String, index: Int, selected: Bool,
                           document: SoundPopoverDocumentView, rowWidth: CGFloat) {
        let row = NSView(frame: NSRect(x: 8, y: rowHeight * CGFloat(optionRows.count),
                                       width: rowWidth, height: rowHeight))
        let hasDelete = index >= 0
        let selectWidth = rowWidth - (hasDelete ? 26 : 0)
        let select = SoundPopoverOptionButton(frame: NSRect(x: 0, y: 0,
                                                             width: selectWidth, height: rowHeight),
                                               title: title, selected: selected)
        select.tag = index
        select.target = self
        select.action = #selector(selectSound(_:))
        row.addSubview(select)

        if hasDelete {
            let remove = SoundPopoverDeleteButton(frame: NSRect(x: rowWidth - 26, y: 3,
                                                                  width: 24, height: 24))
            remove.title = ""
            remove.isBordered = false
            remove.wantsLayer = true
            remove.layer?.cornerRadius = 6
            remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            remove.imageScaling = .scaleProportionallyDown
            remove.contentTintColor = .secondaryLabelColor
            remove.setAccessibilityLabel(L10n.text("삭제: %@", title))
            remove.tag = index
            remove.target = self
            remove.action = #selector(deleteSound(_:))
            row.addSubview(remove)
        }
        document.addSubview(row)
        optionRows.append((view: row, title: title))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let search = notification.object as? NSTextField, search === searchField else { return }
        filterOptions(search)
    }

    private func filterOptions(_ search: NSTextField) {
        guard let document, let scrollView else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleCount = 0
        for entry in optionRows {
            let visible = query.isEmpty || entry.title.localizedCaseInsensitiveContains(query)
            entry.view.isHidden = !visible
            if visible {
                entry.view.frame.origin.y = rowHeight * CGFloat(visibleCount)
                visibleCount += 1
            }
        }
        emptyState?.isHidden = visibleCount > 0
        document.setFrameSize(NSSize(width: document.frame.width,
                                     height: max(listHeight, rowHeight * CGFloat(visibleCount))))
        scrollView.hasVerticalScroller = visibleCount > maximumVisibleRows
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func installOutsideClickMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let buttonRect: NSRect? = {
                guard let button = self.anchorButton, let window = button.window else { return nil }
                return window.convertToScreen(button.convert(button.bounds, to: nil))
            }()
            if !self.panel.frame.contains(NSEvent.mouseLocation),
               !(buttonRect?.contains(NSEvent.mouseLocation) ?? false) {
                self.close()
            }
            return event
        }
    }

    @objc private func selectSound(_ sender: NSButton) {
        let index = sender.tag
        close()
        if index < 0 { onSelectDefault?() }
        else if savedSounds.indices.contains(index) { onSelectSaved?(savedSounds[index].id) }
    }

    @objc private func addSound(_ sender: NSButton) {
        close()
        onAdd?()
    }

    @objc private func deleteSound(_ sender: NSButton) {
        guard savedSounds.indices.contains(sender.tag) else { return }
        let id = savedSounds[sender.tag].id
        close()
        onDelete?(id)
    }
}
