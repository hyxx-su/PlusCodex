import AppKit

/// Published release text is bundled with the app, not fetched by settings.
struct PatchNote: Decodable {
    let version: String
    let publishedAt: String
    let url: URL
    let body: String
    let summary: [String: String]?
    let highlights: [String: [String]]?

    func displayBody(for language: AppLanguage) -> String {
        guard let items = highlights?[language.rawValue], !items.isEmpty else { return body }
        return items.map { "- " + $0 }.joined(separator: "\n")
    }

    static func bundled(in bundle: Bundle = .main) -> [PatchNote] {
        guard let url = bundle.url(forResource: "PatchNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([PatchNote].self, from: data) else { return [] }
        // Compare the base first; a release precedes its own beta in descending order.
        return notes.sorted {
            let lhs = $0.version.split(separator: "-", maxSplits: 1)
            let rhs = $1.version.split(separator: "-", maxSplits: 1)
            let baseOrder = String(lhs[0]).compare(String(rhs[0]), options: .numeric)
            if baseOrder != .orderedSame { return baseOrder == .orderedDescending }
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }
    }
}

private final class PatchNotesDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Match the notification page's top-origin scrolling without exposing space above the title.
private final class PatchNotesClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func scroll(to newOrigin: NSPoint) {
        guard let documentView else {
            super.scroll(to: newOrigin)
            return
        }
        var origin = newOrigin
        origin.y = min(max(origin.y, 0), max(0, documentView.bounds.height - bounds.height))
        super.scroll(to: origin)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        bounds.origin.y = min(max(bounds.origin.y, 0),
            max(0, documentView.bounds.height - bounds.height))
        return bounds
    }
}

private final class PatchNoteDisclosureButton: NSButton {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels and the chevron form one clickable header, not separate hit targets.
        super.hitTest(point) == nil ? nil : self
    }
}

/// Fill the square thumbnail without stretching the shared landscape banner.
private final class PatchNoteThumbnailView: NSImageView {
    private let versionOverlay = NSView()
    private let versionLabel: NSTextField

    init(version: String) {
        versionLabel = NSTextField(labelWithString: version.hasPrefix("v") ? version : "v" + version)
        super.init(frame: .zero)
        versionOverlay.identifier = NSUserInterfaceItemIdentifier("patch-note-version-overlay-\(version)")
        versionOverlay.wantsLayer = true
        versionOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        versionOverlay.setAccessibilityElement(false)
        addSubview(versionOverlay)
        versionLabel.identifier = NSUserInterfaceItemIdentifier("patch-note-image-version-\(version)")
        versionLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        versionLabel.textColor = .white
        versionLabel.alignment = .center
        versionLabel.maximumNumberOfLines = 1
        versionLabel.setAccessibilityElement(false)
        versionOverlay.addSubview(versionLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let height = min(22, bounds.height)
        versionOverlay.frame = NSRect(x: 0, y: isFlipped ? bounds.height - height : 0,
                                      width: bounds.width, height: height)
        versionLabel.frame = NSRect(x: 4, y: (height - 16) / 2,
                                    width: max(0, bounds.width - 8), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class PatchNoteCardView: NSView {
    private static let headerHeight: CGFloat = 112
    override var isFlipped: Bool { true }
    private let note: PatchNote
    private let header = PatchNoteDisclosureButton(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let bannerView: NSImageView?
    private var bodyLabel: NSTextField?
    private var separator: NSBox?
    private(set) var expanded = false
    var onToggle: (() -> Void)?

    init(note: PatchNote, bannerImage: NSImage?) {
        self.note = note
        if let image = bannerImage, image.size.width > 0, image.size.height > 0 {
            let view = PatchNoteThumbnailView(version: note.version)
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageAlignment = .alignCenter
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.layer?.masksToBounds = true
            view.identifier = NSUserInterfaceItemIdentifier("patch-note-banner-\(note.version)")
            view.setAccessibilityElement(false)
            bannerView = view
        } else {
            bannerView = nil
        }
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("patch-note-\(note.version)")
        wantsLayer = true
        setAdaptiveBackgroundColor(.windowBackgroundColor)
        setAdaptiveBorderColor(.separatorColor)
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        header.title = ""
        header.isBordered = false
        header.bezelStyle = .regularSquare
        header.target = self
        header.action = #selector(toggle)
        header.identifier = NSUserInterfaceItemIdentifier("patch-note-toggle-\(note.version)")
        addSubview(header)
        if let bannerView { header.addSubview(bannerView) }
        titleLabel.identifier = NSUserInterfaceItemIdentifier("patch-note-title-\(note.version)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityElement(false)
        header.addSubview(titleLabel)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.cell?.truncatesLastVisibleLine = true
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("patch-note-summary-\(note.version)")
        summaryLabel.setAccessibilityElement(false)
        header.addSubview(summaryLabel)
        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.identifier = NSUserInterfaceItemIdentifier("patch-note-date-\(note.version)")
        dateLabel.setAccessibilityElement(false)
        header.addSubview(dateLabel)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.imageScaling = .scaleProportionallyDown
        chevron.setAccessibilityElement(false)
        header.addSubview(chevron)
        reloadLocalization()
    }

    required init?(coder: NSCoder) { nil }

    func reloadLocalization() {
        let date = ISO8601DateFormatter().date(from: note.publishedAt)
        let dateText = date?.formatted(.dateTime.year().month().day().locale(L10n.locale)) ?? ""
        titleLabel.stringValue = L10n.text("PlusCodex %@ 패치노트", note.version)
        summaryLabel.stringValue = note.summary?[L10n.language.rawValue] ?? note.summary?["ko"] ?? ""
        dateLabel.stringValue = dateText
        bodyLabel?.attributedStringValue = Self.formattedBody(note.displayBody(for: L10n.language))
        header.setAccessibilityLabel(titleLabel.stringValue)
        header.setAccessibilityHelp([summaryLabel.stringValue, dateText,
            L10n.text("버전을 누르면 업데이트 내용을 펼치거나 접습니다.")]
            .filter { !$0.isEmpty }.joined(separator: " · "))
        updateDisclosure()
    }

    private func updateDisclosure() {
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        header.setAccessibilityValue(expanded ? 1 : 0)
    }

    @objc private func toggle() {
        setExpanded(!expanded)
        onToggle?()
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if expanded && bodyLabel == nil {
            // Allocate and measure long release bodies only while they are expanded.
            let label = NSTextField(wrappingLabelWithString: "")
            // The shared field editor must preserve rich-text attributes during selection.
            label.font = .systemFont(ofSize: 11.5)
            label.allowsEditingTextAttributes = true
            label.attributedStringValue = Self.formattedBody(note.displayBody(for: L10n.language))
            label.isEditable = false
            label.isSelectable = true
            label.maximumNumberOfLines = 0
            label.alphaValue = 0
            label.identifier = NSUserInterfaceItemIdentifier("patch-note-body-\(note.version)")
            addSubview(label)
            bodyLabel = label
            let line = NSBox()
            line.boxType = .separator
            line.alphaValue = 0
            addSubview(line)
            separator = line
        }
        updateDisclosure()
    }

    func animateBody() {
        bodyLabel?.animator().alphaValue = expanded ? 1 : 0
        separator?.animator().alphaValue = expanded ? 1 : 0
    }

    func finishTransition() {
        if !expanded {
            bodyLabel?.removeFromSuperview()
            separator?.removeFromSuperview()
            bodyLabel = nil
            separator = nil
        } else {
            bodyLabel?.alphaValue = 1
            separator?.alphaValue = 1
        }
    }

    func height(for width: CGFloat) -> CGFloat {
        let headerHeight = Self.headerHeight
        guard expanded, let bodyLabel, let cell = bodyLabel.cell else { return headerHeight }
        let textWidth = max(1, width - 32)
        // Use the field's own wrapping/insets so the final lines are not clipped.
        let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth,
                                                       height: .greatestFiniteMagnitude))
        return headerHeight + 16 + ceil(measured.height) + 16
    }

    override func layout() {
        super.layout()
        let headerHeight = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let thumbnailWidth = min(88, max(0, bounds.width * 0.24))
        if let bannerView {
            bannerView.frame = NSRect(x: 12, y: (headerHeight - thumbnailWidth) / 2,
                                      width: thumbnailWidth, height: thumbnailWidth)
        }
        let textX: CGFloat = bannerView == nil ? 16 : 12 + thumbnailWidth + 14
        let textWidth = max(0, bounds.width - textX - 36)
        titleLabel.frame = NSRect(x: textX, y: 13, width: textWidth, height: 20)
        summaryLabel.frame = NSRect(x: textX, y: 38, width: textWidth, height: 32)
        dateLabel.frame = NSRect(x: textX, y: 81, width: textWidth, height: 16)
        chevron.frame = NSRect(x: bounds.width - 28, y: (headerHeight - 14) / 2, width: 14, height: 14)
        separator?.frame = NSRect(x: 16, y: headerHeight, width: bounds.width - 32, height: 1)
        if let bodyLabel, let cell = bodyLabel.cell {
            let width = max(1, bounds.width - 32)
            let height = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                height: .greatestFiniteMagnitude)).height)
            // Keep text layout fixed while the card clips/reveals it during its height animation.
            bodyLabel.frame = NSRect(x: 16, y: headerHeight + 16, width: width, height: height)
        }
    }

    private static func formattedBody(_ body: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        // A trailing newline creates an empty final line in NSTextField's height measurement.
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let heading = line.hasPrefix("#")
            var text = heading ? line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression) : line
            if text.hasPrefix("- ") { text = "• " + text.dropFirst(2) }
            text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3
            let isLast = index == lines.count - 1
            paragraph.paragraphSpacing = isLast ? 0 : (heading ? 6 : 3)
            result.append(NSAttributedString(string: text + (isLast ? "" : "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: heading ? 13 : 11.5, weight: heading ? .medium : .regular),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}

/// A native settings page with one non-persistent release disclosure open at a time.
final class PatchNotesView: NSView {
    private let scroll = NSScrollView()
    private let document = PatchNotesDocumentView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sectionLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let currentVersion: String
    private let cards: [PatchNoteCardView]
    private var disclosureGeneration = 0
    private var animatingDisclosure = false
    private var disclosureLayoutSize = NSSize.zero

    init(frame: NSRect, notes: [PatchNote] = PatchNote.bundled(),
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
         bannerImage: NSImage? = Bundle.main.url(forResource: "PatchNotesBanner", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }) {
        self.currentVersion = currentVersion.hasPrefix("v") ? currentVersion : "v" + currentVersion
        // All version cards share one image rather than decoding the banner for each release.
        cards = notes.map { PatchNoteCardView(note: $0, bannerImage: bannerImage) }
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("patch-notes-page")
        autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.contentView = PatchNotesClipView()
        scroll.documentView = document
        addSubview(scroll)
        titleLabel.font = .systemFont(ofSize: 18, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.identifier = NSUserInterfaceItemIdentifier("patch-notes-page-title")
        document.addSubview(titleLabel)
        sectionLabel.font = .systemFont(ofSize: 14, weight: .medium)
        sectionLabel.textColor = .labelColor
        sectionLabel.identifier = NSUserInterfaceItemIdentifier("patch-notes-section-title")
        document.addSubview(sectionLabel)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = !cards.isEmpty
        document.addSubview(emptyLabel)
        for card in cards {
            document.addSubview(card)
            card.onToggle = { [weak self, weak card] in
                guard let self, let card else { return }
                if card.expanded {
                    self.cards.filter { $0 !== card }.forEach { $0.setExpanded(false) }
                }
                self.layoutCards(animated: true)
            }
        }
        reloadLocalization()
    }

    required init?(coder: NSCoder) { nil }

    func reloadLocalization() {
        titleLabel.stringValue = L10n.text("패치노트")
        sectionLabel.stringValue = L10n.text("패치노트 (현재 버전: %@)", currentVersion)
        emptyLabel.stringValue = L10n.text("패치노트를 불러올 수 없습니다.")
        cards.forEach { $0.reloadLocalization() }
        if animatingDisclosure { layoutCards() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if !animatingDisclosure || disclosureLayoutSize != bounds.size { layoutCards() }
    }

    private func layoutCards(animated: Bool = false) {
        let width = bounds.width
        let contentWidth = max(0, width - 32)
        titleLabel.frame = NSRect(x: 13, y: 17, width: contentWidth, height: 24)
        sectionLabel.frame = NSRect(x: 13, y: 59, width: contentWidth, height: 24)
        emptyLabel.frame = NSRect(x: 13, y: 99, width: contentWidth, height: 48)
        var y: CGFloat = 91
        var targets: [(PatchNoteCardView, NSRect)] = []
        for card in cards {
            let frame = NSRect(x: 13, y: y, width: contentWidth, height: card.height(for: contentWidth))
            targets.append((card, frame))
            y = frame.maxY + 12
        }
        let documentSize = NSSize(width: width, height: max(bounds.height, y + 12))
        let animate = animated && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        disclosureGeneration += 1
        let generation = disclosureGeneration
        animatingDisclosure = animate
        disclosureLayoutSize = bounds.size
        let finish = { [weak self] in
            // A newer click owns the transition; stale completions must not remove its body.
            guard let self, self.disclosureGeneration == generation else { return }
            self.animatingDisclosure = false
            self.cards.forEach { $0.finishTransition() }
            self.clampScrollPosition()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animate ? 0.3 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (card, frame) in targets {
                card.animator().frame = frame
                card.needsLayout = true
                card.animateBody()
            }
            document.animator().setFrameSize(documentSize)
        }, completionHandler: animate ? finish : nil)
        if !animate { finish() }
    }

    private func clampScrollPosition() {
        let origin = scroll.contentView.bounds.origin
        // Preserve the clicked header position; clamp only when collapse shortens the document.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, origin.y),
            max(0, document.bounds.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
