import AppKit

/// Published release text is bundled with the app, not fetched by settings.
struct PatchNote: Decodable {
    let version: String
    let publishedAt: String
    let url: URL
    let body: String
    let summary: [String: String]?

    static func bundled(in bundle: Bundle = .main) -> [PatchNote] {
        guard let url = bundle.url(forResource: "PatchNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([PatchNote].self, from: data) else { return [] }
        return notes.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
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

private final class PatchNoteCardView: NSView {
    private static let captionHeight: CGFloat = 78
    override var isFlipped: Bool { true }
    private let note: PatchNote
    private let header = PatchNoteDisclosureButton(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let chevron = NSImageView()
    private let bannerView: NSImageView?
    private var bodyLabel: NSTextField?
    private var separator: NSBox?
    private var expanded = false
    var onToggle: (() -> Void)?

    init(note: PatchNote, bannerImage: NSImage?) {
        self.note = note
        if let image = bannerImage, image.size.width > 0, image.size.height > 0 {
            let view = NSImageView()
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageAlignment = .alignCenter
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
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("patch-note-summary-\(note.version)")
        summaryLabel.setAccessibilityElement(false)
        header.addSubview(summaryLabel)
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
        // Older note resources without summaries keep their existing date caption.
        summaryLabel.stringValue = note.summary?[L10n.language.rawValue] ?? note.summary?["ko"] ?? dateText
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
        expanded.toggle()
        if expanded {
            // Allocate and measure long release bodies only while they are expanded.
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = Self.formattedBody(note.body)
            label.isSelectable = true
            label.maximumNumberOfLines = 0
            label.identifier = NSUserInterfaceItemIdentifier("patch-note-body-\(note.version)")
            addSubview(label)
            bodyLabel = label
            let line = NSBox()
            line.boxType = .separator
            addSubview(line)
            separator = line
        } else {
            bodyLabel?.removeFromSuperview()
            separator?.removeFromSuperview()
            bodyLabel = nil
            separator = nil
        }
        updateDisclosure()
        onToggle?()
    }

    private func bannerHeight(for width: CGFloat) -> CGFloat {
        guard let image = bannerView?.image else { return 0 }
        return ceil(max(0, width) * image.size.height / image.size.width)
    }

    func height(for width: CGFloat) -> CGFloat {
        let headerHeight = bannerHeight(for: width) + Self.captionHeight
        guard let bodyLabel, let cell = bodyLabel.cell else { return headerHeight }
        let textWidth = max(1, width - 32)
        // Use the field's own wrapping/insets so the final lines are not clipped.
        let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth,
                                                       height: .greatestFiniteMagnitude))
        return headerHeight + 16 + ceil(measured.height) + 6 + 16
    }

    override func layout() {
        super.layout()
        let bannerHeight = bannerHeight(for: bounds.width)
        let headerHeight = bannerHeight + Self.captionHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        bannerView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bannerHeight)
        titleLabel.frame = NSRect(x: 16, y: bannerHeight + 13, width: max(0, bounds.width - 64), height: 20)
        summaryLabel.frame = NSRect(x: 16, y: bannerHeight + 37, width: max(0, bounds.width - 64), height: 32)
        chevron.frame = NSRect(x: bounds.width - 32, y: bannerHeight + 32, width: 14, height: 14)
        separator?.frame = NSRect(x: 16, y: headerHeight, width: bounds.width - 32, height: 1)
        bodyLabel?.frame = NSRect(x: 16, y: headerHeight + 16,
                                  width: max(0, bounds.width - 32),
                                  height: max(0, bounds.height - headerHeight - 32))
    }

    private static func formattedBody(_ body: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let heading = line.hasPrefix("#")
            var text = heading ? line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression) : line
            if text.hasPrefix("- ") { text = "• " + text.dropFirst(2) }
            text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = heading ? 6 : 3
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: heading ? 13 : 11.5, weight: heading ? .medium : .regular),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}

/// A native settings page with independent, non-persistent release disclosures.
final class PatchNotesView: NSView {
    private let scroll = NSScrollView()
    private let document = PatchNotesDocumentView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sectionLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let currentVersion: String
    private let cards: [PatchNoteCardView]

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
            card.onToggle = { [weak self] in self?.layoutCards() }
        }
        reloadLocalization()
    }

    required init?(coder: NSCoder) { nil }

    func reloadLocalization() {
        titleLabel.stringValue = L10n.text("패치노트")
        sectionLabel.stringValue = L10n.text("패치노트 (현재 버전: %@)", currentVersion)
        emptyLabel.stringValue = L10n.text("패치노트를 불러올 수 없습니다.")
        cards.forEach { $0.reloadLocalization() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutCards()
    }

    private func layoutCards() {
        let origin = scroll.contentView.bounds.origin
        let width = bounds.width
        let contentWidth = max(0, width - 32)
        titleLabel.frame = NSRect(x: 13, y: 17, width: contentWidth, height: 24)
        sectionLabel.frame = NSRect(x: 13, y: 59, width: contentWidth, height: 24)
        emptyLabel.frame = NSRect(x: 13, y: 99, width: contentWidth, height: 48)
        var y: CGFloat = 91
        for card in cards {
            card.frame = NSRect(x: 13, y: y, width: contentWidth, height: card.height(for: contentWidth))
            card.needsLayout = true
            y = card.frame.maxY + 12
        }
        document.setFrameSize(NSSize(width: width, height: max(bounds.height, y + 12)))
        // Preserve the clicked header position; clamp only when collapse shortens the document.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, origin.y),
            max(0, document.bounds.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
