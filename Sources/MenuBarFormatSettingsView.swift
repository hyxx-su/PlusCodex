import AppKit

final class MenuBarTokenHelpButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// Owns only the editor and preview for each provider's menu-bar text.
final class MenuBarFormatSettingsView: NSView, NSTextFieldDelegate, NSPopoverDelegate {
    static let preferredHeight: CGFloat = 468
    private let settings: ProviderSettings
    private var fields: [AIProvider: NSTextField] = [:]
    private var previews: [AIProvider: NSTextField] = [:]
    private var errors: [AIProvider: NSTextField] = [:]
    private var resetButtons: [AIProvider: NSButton] = [:]
    private var presetPickers: [AIProvider: NSPopUpButton] = [:]
    private var helpButtons: [AIProvider: NSButton] = [:]
    private var providerPresets: [AIProvider: [String]] = [:]
    private var snapshots: [AIProvider: Quota] = [:]
    private let title = NSTextField(labelWithString: "")
    private let card = NSView()
    private var rows: [AIProvider: NSView] = [:]
    private var separators: [AIProvider: NSView] = [:]
    private var visibleProviders: [AIProvider] = []
    var onHeightChanged: (() -> Void)?

    init(frame: NSRect, settings: ProviderSettings) {
        self.settings = settings
        super.init(frame: frame)
        title.frame = NSRect(x: 0, y: bounds.height - 24, width: bounds.width, height: 24)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        addSubview(title)
        card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 432)
        card.wantsLayer = true
        card.setAdaptiveBackgroundColor(.windowBackgroundColor)
        card.setAdaptiveBorderColor(.separatorColor)
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 12
        addSubview(card)
        for (index, provider) in AIProvider.allCases.enumerated() {
            let row = NSView(frame: NSRect(x: 0, y: card.bounds.height - CGFloat((index + 1) * 108),
                                          width: card.bounds.width, height: 108))
            rows[provider] = row
            card.addSubview(row)
            let top: CGFloat = 108
            let headerCenterY = top - 23
            let icon = NSImageView(frame: NSRect(x: 14, y: headerCenterY - 11, width: 22, height: 22))
            icon.image = CodexStatusIcon.image(size: 22, offline: false, provider: provider)
            icon.identifier = NSUserInterfaceItemIdentifier("menuBarFormat-icon-\(provider.rawValue)")
            icon.setAccessibilityElement(false)
            row.addSubview(icon)
            let name = NSTextField(labelWithString: provider.name)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            // Match the font height, then lift the text ink 1pt to optically align with the symbols.
            name.sizeToFit()
            name.frame.origin = NSPoint(x: 42, y: headerCenterY - name.frame.height / 2 + 1)
            name.identifier = NSUserInterfaceItemIdentifier("menuBarFormat-name-\(provider.rawValue)")
            row.addSubview(name)
            let helpImage = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)!
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))!
            helpImage.size = NSSize(width: 12, height: 12)
            let help = MenuBarTokenHelpButton(image: helpImage, target: self, action: #selector(showHelp(_:)))
            help.isBordered = false
            help.contentTintColor = .secondaryLabelColor
            help.imageScaling = .scaleNone
            help.frame = NSRect(x: name.frame.maxX + 5, y: headerCenterY - 8, width: 16, height: 16)
            help.tag = index
            help.identifier = NSUserInterfaceItemIdentifier("menuBarFormat-help-\(provider.rawValue)")
            help.onHoverChanged = { [weak self, weak help] inside in
                guard let self, let help else { return }
                if inside {
                    self.hoveredHelpButton = help
                    self.pendingHelpClose?.cancel()
                    self.pendingHelpOpen?.cancel()
                    let work = DispatchWorkItem { [weak self, weak help] in
                        guard let self, let help, self.hoveredHelpButton === help,
                              help.window != nil, !help.isHiddenOrHasHiddenAncestor else { return }
                        self.showHelp(help)
                    }
                    self.pendingHelpOpen = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                } else if self.hoveredHelpButton === help {
                    self.hoveredHelpButton = nil
                    self.pendingHelpOpen?.cancel()
                    self.scheduleHelpClose()
                }
            }
            helpButtons[provider] = help
            row.addSubview(help)
            let reset = NSButton(title: "", target: self, action: #selector(resetFormat(_:)))
            reset.bezelStyle = .rounded
            reset.tag = index
            reset.controlSize = .small
            reset.font = .systemFont(ofSize: 10.5)
            reset.frame = NSRect(x: 365, y: top - 32, width: 56, height: 22)
            reset.identifier = NSUserInterfaceItemIdentifier("menuBarFormat-reset-\(provider.rawValue)")
            row.addSubview(reset)
            resetButtons[provider] = reset
            let field = NSTextField(frame: NSRect(x: 16, y: top - 70, width: 314, height: 26))
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.bezelStyle = .roundedBezel
            field.stringValue = settings.menuBarFormat(provider)
            field.placeholderString = MenuBarFormat.defaultFormat
            field.identifier = NSUserInterfaceItemIdentifier("menuBarFormat-\(provider.rawValue)")
            field.delegate = self
            row.addSubview(field)
            fields[provider] = field
            let presets = NSPopUpButton(frame: NSRect(x: 338, y: top - 70, width: 83, height: 26))
            presets.controlSize = .small
            presets.font = .systemFont(ofSize: 11)
            presets.tag = index
            presets.target = self
            presets.action = #selector(selectPreset(_:))
            presets.identifier = NSUserInterfaceItemIdentifier("menuBarFormat-presets-\(provider.rawValue)")
            row.addSubview(presets)
            presetPickers[provider] = presets
            let preview = NSTextField(labelWithString: "")
            preview.frame = NSRect(x: 16, y: top - 96, width: 405, height: 18)
            preview.font = .systemFont(ofSize: 11)
            preview.textColor = .secondaryLabelColor
            preview.lineBreakMode = .byTruncatingTail
            row.addSubview(preview)
            previews[provider] = preview
            let error = NSTextField(labelWithString: "")
            error.frame = preview.frame
            error.font = .systemFont(ofSize: 11)
            error.textColor = .systemRed
            row.addSubview(error)
            errors[provider] = error
            if index < AIProvider.allCases.count - 1 {
                let line = NSBox(frame: NSRect(x: 16, y: top - 108, width: 405, height: 1))
                line.boxType = .separator
                row.addSubview(line)
                separators[provider] = line
            }
        }
        reloadLocalization()
        synchronize()
    }

    required init?(coder: NSCoder) { nil }

    func reloadLocalization() {
        title.stringValue = L10n.text("메뉴바 표시 형식")
        for provider in AIProvider.allCases {
            fields[provider]?.setAccessibilityLabel(L10n.text("%@ 메뉴바 표시 형식", provider.name))
            resetButtons[provider]?.title = L10n.text("기본값")
            resetButtons[provider]?.setAccessibilityLabel(L10n.text("%@ 표시 형식 초기화", provider.name))
            presetPickers[provider]?.setAccessibilityLabel(L10n.text("%@ 표시 형식 빠른 선택", provider.name))
            helpButtons[provider]?.setAccessibilityLabel(L10n.text("%@에서 사용 가능한 토큰", provider.name))
            updateHelpAndPresets(provider, force: true)
            refreshPreview(provider)
        }
    }

    func synchronize(enabledProviders: Set<AIProvider>? = nil) {
        let visible = AIProvider.allCases.filter { enabledProviders?.contains($0) ?? settings.enabled($0) }
        if visible != visibleProviders {
            pendingHelpOpen?.cancel()
            pendingHelpClose?.cancel()
            hoveredHelpButton = nil
            helpPopover?.close()
            visibleProviders = visible
        }
        let cardHeight = CGFloat(visible.count) * 108
        let height: CGFloat = visible.isEmpty ? 0 : cardHeight + 36
        let changedHeight = frame.height != height
        setFrameSize(NSSize(width: frame.width, height: height))
        isHidden = visible.isEmpty
        title.frame.origin.y = max(0, height - 24)
        card.setFrameSize(NSSize(width: bounds.width, height: cardHeight))
        for provider in AIProvider.allCases {
            guard let row = rows[provider] else { continue }
            if let index = visible.firstIndex(of: provider) {
                row.isHidden = false
                row.frame.origin.y = cardHeight - CGFloat(index + 1) * 108
                separators[provider]?.isHidden = index == visible.count - 1
            } else {
                row.isHidden = true
                row.frame.origin.y = 0
            }
        }
        for provider in AIProvider.allCases {
            if let field = fields[provider], field.currentEditor() == nil,
               MenuBarFormat.isValid(field.stringValue) {
                field.stringValue = settings.menuBarFormat(provider)
            }
            refreshPreview(provider)
        }
        if changedHeight { onHeightChanged?() }
    }

    func updateQuota(_ quota: Quota?, provider: AIProvider) {
        if let quota { snapshots[provider] = quota } else { snapshots.removeValue(forKey: provider) }
        updateHelpAndPresets(provider)
        refreshPreview(provider)
    }

    private func updateHelpAndPresets(_ provider: AIProvider, force: Bool = false) {
        let help = MenuBarFormat.helpText(provider: provider, quota: snapshots[provider])
        helpButtons[provider]?.toolTip = nil
        helpButtons[provider]?.setAccessibilityHelp(help)
        let formats = MenuBarFormat.presets(quota: snapshots[provider])
        guard force || providerPresets[provider] != formats else { return }
        providerPresets[provider] = formats
        guard let picker = presetPickers[provider] else { return }
        picker.removeAllItems()
        picker.addItem(withTitle: L10n.text("빠른 선택"))
        for format in formats { picker.addItem(withTitle: format) }
    }

    @objc private func showHelp(_ sender: NSButton) {
        guard AIProvider.allCases.indices.contains(sender.tag) else { return }
        if helpPopover?.isShown == true, helpAnchor === sender { return }
        pendingHelpClose?.cancel()
        helpPopover?.close()
        helpContentHovered = false
        let popover = NSPopover()
        let content = MenuBarTokenHelpView(quota: snapshots[AIProvider.allCases[sender.tag]])
        content.onHoverChanged = { [weak self] inside in
            guard let self else { return }
            self.helpContentHovered = inside
            if inside { self.pendingHelpClose?.cancel() }
            else { self.scheduleHelpClose() }
        }
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        helpPopover = popover
        helpAnchor = sender
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }
    private var helpPopover: NSPopover?
    private weak var helpAnchor: NSButton?
    private weak var hoveredHelpButton: NSButton?
    private var helpContentHovered = false
    private var pendingHelpOpen: DispatchWorkItem?
    private var pendingHelpClose: DispatchWorkItem?

    private func scheduleHelpClose() {
        pendingHelpClose?.cancel()
        guard hoveredHelpButton == nil, !helpContentHovered else { return }
        // Allow the pointer to cross the popover arrow/gap before dismissing it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredHelpButton == nil, !self.helpContentHovered else { return }
            self.helpPopover?.close()
        }
        pendingHelpClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === helpPopover else { return }
        helpPopover = nil
        helpAnchor = nil
        helpContentHovered = false
        pendingHelpClose?.cancel()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            pendingHelpOpen?.cancel()
            pendingHelpClose?.cancel()
            hoveredHelpButton = nil
            helpPopover?.close()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func refreshPreview(_ provider: AIProvider) {
        guard let field = fields[provider] else { return }
        let valid = MenuBarFormat.isValid(field.stringValue)
        errors[provider]?.stringValue = valid ? "" : L10n.text("지원 토큰·괄호·80자 제한을 확인하세요. 저장되지 않았습니다.")
        errors[provider]?.isHidden = valid
        previews[provider]?.isHidden = !valid
        let now = Date()
        let text = MenuBarFormat.render(valid ? field.stringValue : settings.menuBarFormat(provider),
            quota: snapshots[provider], showRemaining: settings.showRemaining(provider), now: now)
        let preview = text.isEmpty ? L10n.text("아이콘만 표시") : text
        previews[provider]?.stringValue = snapshots[provider] == nil && !text.isEmpty
            ? L10n.text("미리보기: 사용량 조회 후 표시됩니다.") : L10n.text("미리보기: %@", preview)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let provider = fields.first(where: { $0.value === field })?.key else { return }
        refreshPreview(provider)
        settings.setMenuBarFormat(field.stringValue, for: provider)
    }

    @objc private func resetFormat(_ sender: NSButton) { setFormat(MenuBarFormat.defaultFormat, tag: sender.tag) }
    @objc private func selectPreset(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard AIProvider.allCases.indices.contains(sender.tag),
              let formats = providerPresets[AIProvider.allCases[sender.tag]], formats.indices.contains(index) else { return }
        setFormat(formats[index], tag: sender.tag)
        sender.selectItem(at: 0)
    }
    private func setFormat(_ value: String, tag: Int) {
        guard AIProvider.allCases.indices.contains(tag) else { return }
        let provider = AIProvider.allCases[tag]
        window?.makeFirstResponder(nil)
        fields[provider]?.stringValue = value
        settings.setMenuBarFormat(value, for: provider)
        refreshPreview(provider)
    }
}
