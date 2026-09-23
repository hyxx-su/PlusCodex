import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

private final class LanguageOptionButton: NSButton {
    var isSelectedOption = false { didSet { updateBackground() } }
    private var isPointerInside = false { didSet { updateBackground() } }
    private weak var titleLabel: NSTextField?
    private(set) var displayTitle = ""

    func setDisplayTitle(_ title: String) {
        displayTitle = title
        titleLabel?.stringValue = title
        titleLabel?.needsDisplay = true
        setAccessibilityLabel(title)
    }

    func configureTitleLabel(width: CGFloat) {
        title = ""
        let label = CenteredTitleLabel(labelWithString: displayTitle)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 8, y: 0, width: max(0, width - 36), height: 30)
        label.autoresizingMask = [.width]
        label.setAccessibilityElement(false)
        addSubview(label)
        titleLabel = label
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        super.mouseExited(with: event)
    }

    private func updateBackground() {
        // Selection is communicated by the checkmark. The row background is
        // reserved for the pointer hover state, matching the reference menu.
        layer?.backgroundColor = isPointerInside
            ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
            : NSColor.clear.cgColor
    }
}

private final class PressFeedbackButton: NSButton {
    private var loadingIndicator: NSProgressIndicator?
    private var showsLoading = false

    func setLoading(_ loading: Bool) {
        if loading && loadingIndicator == nil {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isIndeterminate = true
            indicator.isDisplayedWhenStopped = false
            indicator.setAccessibilityElement(false)
            addSubview(indicator)
            loadingIndicator = indicator
            needsLayout = true
        }
        if showsLoading != loading {
            showsLoading = loading
            if loading {
                loadingIndicator?.startAnimation(nil)
            } else {
                loadingIndicator?.stopAnimation(nil)
            }
        }
        title = loading ? "" : L10n.text("알림 테스트")
        setAccessibilityLabel(L10n.text(loading ? "알림 테스트 중지" : "알림 테스트"))
        toolTip = loading ? L10n.text("다시 누르면 알림 테스트를 중지합니다.") : nil
    }

    override func layout() {
        super.layout()
        loadingIndicator?.frame = NSRect(x: (bounds.width - 16) / 2,
                                         y: (bounds.height - 16) / 2,
                                         width: 16, height: 16)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === loadingIndicator ? self : hitView
    }

    override func mouseDown(with event: NSEvent) {
        let restingAlpha = alphaValue
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 0.72
        }
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = restingAlpha
        }
    }
}

private final class CenteredTitleLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        guard !stringValue.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor ?? .labelColor
        ]
        let textSize = (stringValue as NSString).size(withAttributes: attributes)
        let textRect = NSRect(x: 0,
                              y: (bounds.height - textSize.height) / 2,
                              width: bounds.width,
                              height: textSize.height)
        (stringValue as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

/// Prevents the notification document from elastically moving beyond its
/// actual scroll range, which would expose an artificial blank area above
/// the page title.
private final class NotificationClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func scroll(to newOrigin: NSPoint) {
        // NSClipView.scroll(to:) does not pass through constrainBoundsRect.
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

        let maximumOriginY = max(0, documentView.bounds.height - bounds.height)
        bounds.origin.y = min(max(bounds.origin.y, 0), maximumOriginY)
        return bounds
    }
}

/// Keeps the notification document's natural origin at the top of the
/// viewport so the page does not need to be positioned by scrolling to its
/// maximum origin.
private final class NotificationDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class FooterLinkLabel: NSTextField {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard !stringValue.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor ?? .labelColor
        ]
        let textSize = (stringValue as NSString).size(withAttributes: attributes)
        let textRect = NSRect(x: 0,
                              y: (bounds.height - textSize.height) / 2,
                              width: bounds.width,
                              height: textSize.height)
        (stringValue as NSString).draw(in: textRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Draws the language control as one centered content group. NSButton's
/// built-in title/image layout centers the title independently and leaves a
/// trailing image at the edge, which makes the control look right-heavy.
private final class LanguagePickerButton: NSButton {
    private let titleLabel = CenteredTitleLabel(labelWithString: "")
    private let chevronView = NSImageView()
    private let chevronWidth: CGFloat = 14
    private let groupGap: CGFloat = 5
    // Keep the Korean control's current optical insets. Longer labels grow
    // to the left while preserving these same insets and the right edge.
    private let leadingInset: CGFloat = 10
    private let trailingInset: CGFloat = 6
    private let minimumWidth: CGFloat = 78

    var centersTitleInButton = false {
        didSet { needsLayout = true }
    }

    var displayTitle = "" {
        didSet {
            titleLabel.stringValue = displayTitle
            titleLabel.needsDisplay = true
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        chevronView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11.5, weight: .regular))
        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.contentTintColor = .labelColor
        chevronView.setAccessibilityElement(false)
        addSubview(chevronView)
    }

    required init?(coder: NSCoder) { nil }

    private var measuredTitleWidth: CGFloat {
        let font = titleLabel.font ?? .systemFont(ofSize: 12.5)
        return max(0, (displayTitle as NSString).size(withAttributes: [.font: font]).width)
    }

    fileprivate var preferredWidth: CGFloat {
        return max(minimumWidth,
                   ceil(measuredTitleWidth + groupGap + chevronWidth + leadingInset + trailingInset))
    }

    override func layout() {
        super.layout()
        let availableTitleWidth = max(0, bounds.width - leadingInset - trailingInset - groupGap - chevronWidth)
        let titleWidth = min(measuredTitleWidth, availableTitleWidth)
        let groupWidth = titleWidth + groupGap + chevronWidth
        let groupX = max(leadingInset, bounds.width - groupWidth - trailingInset)
        // Draw the title against the complete control height so the glyph
        // itself, rather than NSTextField's default cell frame, is centered.
        let titleHeight = bounds.height
        let y: CGFloat = 0
        let chevronX = centersTitleInButton
            ? bounds.width - trailingInset - chevronWidth
            : groupX + titleWidth + groupGap
        // Center the duration title in the space before the chevron so its
        // left inset matches the gap between the title and icon.
        let titleX = centersTitleInButton ? (chevronX - titleWidth) / 2 : groupX
        titleLabel.frame = NSRect(x: titleX, y: y, width: titleWidth, height: titleHeight)
        chevronView.frame = NSRect(x: chevronX,
                                   y: (bounds.height - chevronWidth) / 2,
                                   width: chevronWidth, height: chevronWidth)
    }
}

private final class LanguagePopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AISettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settings: ProviderSettings
    private let notificationSettings: NotificationSettings
    private let login: LoginLaunchController
    private let language: LanguageSettings
    private let languagePicker = LanguagePickerButton(frame: .zero)
    private lazy var languagePopover: LanguagePopoverPanel = {
        let panel = LanguagePopoverPanel(contentRect: .zero,
                            styleMask: [.borderless],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Avoid the heavy default NSPanel shadow; the panel edge should stay subtle.
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }()
    private var languagePopoverEventMonitor: Any?
    private var languagePopoverContentSize = NSSize.zero
    private var notificationSoundPopover: NotificationSoundPopover?
    private var notificationStyleGuidancePopover: NSPopover?
    private weak var languageSearchField: NSTextField?
    private weak var languageEmptyState: NSTextField?
    private weak var navigationSearchField: NSTextField?
    private weak var navigationSearchContainer: NSView?
    private weak var navigationClearButton: NSButton?
    private weak var navigationEmptyState: NSTextField?
    private weak var closeButton: NSButton?
    private weak var releaseButton: FooterLinkLabel?
    private weak var makerButton: FooterLinkLabel?
    private weak var notificationPermissionToggle: NSSwitch?
    private weak var notificationSoundPicker: LanguagePickerButton?
    private weak var notificationSoundDurationPicker: LanguagePickerButton?
    private weak var notificationSoundDurationDescription: NSTextField?
    private var notificationAlertStyle: UNAlertStyle?
    private weak var notificationScrollView: NSScrollView?
    private weak var notificationPermissionCard: NSView?
    private weak var notificationOptionsHeader: NSView?
    private weak var notificationOptionsCard: NSView?
    private var notificationTopSoundRows: [(view: NSView, frame: NSRect)] = []
    private var notificationConditionalSoundRows: [(view: NSView, frame: NSRect)] = []
    private var notificationConditionalSeparators: [(view: NSView, frame: NSRect)] = []
    private var notificationTopSeparator: (view: NSView, frame: NSRect)?
    private var notificationOptionsBaseFrames: [(view: NSView, frame: NSRect)] = []
    private var notificationLayoutReady = false
    private var notificationSoundLayoutExpanded: Bool?
    private var notificationLayoutGeneration = 0
    private var notificationExpandedCardHeight: CGFloat = 390
    private var notificationExpandedDocumentHeight: CGFloat = 0
    private var notificationSoundDurationMenu: NSMenu?
    private weak var soundVolumeSlider: NSSlider?
    private weak var soundVolumeLabel: NSTextField?
    private weak var soundTestButton: PressFeedbackButton?
    private var activeSoundTestRequestID: String?
    private var soundTestCancelUnlocked = false
    private var isSendingSoundTestNotification: Bool { activeSoundTestRequestID != nil }
    private var lastSoundTestRequestID: String?
    private var notificationToggles: [NotificationKind: NSSwitch] = [:]
    private var languageOptions: [LanguageOptionButton] = []
    private var languageCheckmarks: [NSImageView] = []
    private var localizedFields: [(field: NSTextField, key: String)] = []
    private var navigationKeys: [String] = []
    private var pages: [NSView] = []
    private var navigation: [NSButton] = []
    private var navigationTitles: [String] = []
    private var navigationSearchRows: [(button: NSButton, categoryIndex: Int,
                                        titleKey: String, isParent: Bool)] = []
    private var toggles: [AIProvider: NSSwitch] = [:]
    private var statuses: [AIProvider: NSTextField] = [:]
    private let loginToggle = NSSwitch()
    private let usageDisplayToggle = NSSwitch()
    private let usageDisplayDescription = NSTextField(labelWithString: "")
    private let loginStatus = NSTextField(labelWithString: "")
    private let notificationStatus = NSTextField(labelWithString: L10n.text("앱의 알림을 받습니다."))

    init(settings: ProviderSettings, notificationSettings: NotificationSettings = NotificationSettings(),
         login: LoginLaunchController = LoginLaunchController(),
         language: LanguageSettings = LanguageSettings()) {
        self.settings = settings
        self.notificationSettings = notificationSettings
        self.login = login
        self.language = language
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L10n.text("설정")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange),
                                               name: .plusCodexLanguageDidChange, object: nil)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 16
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.masksToBounds = true
        window.contentView = root
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        @discardableResult
        func label(_ text: String, in parent: NSView, x: CGFloat, y: CGFloat,
                   width: CGFloat, size: CGFloat = 13, bold: Bool = false,
                   secondary: Bool = false, localized: Bool = true) -> NSTextField {
            let value = localized ? L10n.text(text) : text
            let field = NSTextField(labelWithString: value)
            field.font = .systemFont(ofSize: size, weight: bold ? .medium : .regular)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.frame = NSRect(x: x, y: y, width: width, height: size > 20 ? 30 : 24)
            field.lineBreakMode = .byTruncatingTail
            parent.addSubview(field)
            if localized { localizedFields.append((field: field, key: text)) }
            return field
        }
        func separator(in page: NSView, y: CGFloat) -> NSBox {
            let line = NSBox(frame: NSRect(x: 16, y: y, width: 437, height: 1))
            line.boxType = .separator
            page.addSubview(line)
            return line
        }
        func placeSwitch(_ toggle: NSSwitch, in page: NSView, centerY: CGFloat) {
            toggle.controlSize = .mini
            toggle.sizeToFit()
            toggle.setFrameOrigin(NSPoint(x: page.bounds.width - 16 - toggle.frame.width,
                                          y: centerY - toggle.frame.height / 2))
            page.addSubview(toggle)
        }
        func status(_ field: NSTextField, in page: NSView, y: CGFloat, width: CGFloat = 400) {
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.frame = NSRect(x: 16, y: y, width: width, height: 18)
            page.addSubview(field)
        }

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("닫기"))!,
                             target: self, action: #selector(returnToApp))
        close.image = close.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        close.isBordered = false
        close.contentTintColor = .labelColor
        close.frame = NSRect(x: 15, y: 384, width: 28, height: 28)
        close.setAccessibilityLabel(L10n.text("닫기"))
        root.addSubview(close)
        closeButton = close
        let searchContainer = NSView(frame: NSRect(x: 10, y: 335, width: 188, height: 32))
        searchContainer.wantsLayer = true
        searchContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        searchContainer.layer?.cornerRadius = 16
        searchContainer.layer?.borderWidth = 1
        searchContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        let searchIcon = NSImageView(frame: NSRect(x: 13, y: 8, width: 16, height: 16))
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular))
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.contentTintColor = .secondaryLabelColor
        searchContainer.addSubview(searchIcon)
        let search = NSTextField(frame: NSRect(x: 36, y: -2, width: 146, height: 26))
        search.placeholderString = L10n.text("설정 검색")
        search.font = .systemFont(ofSize: 12.5)
        search.isBezeled = false
        search.isEditable = true
        search.isSelectable = true
        search.drawsBackground = false
        search.focusRingType = .none
        search.alignment = .left
        search.delegate = self
        search.target = self
        search.action = #selector(filterNavigation(_:))
        search.setAccessibilityLabel(L10n.text("설정 검색"))
        searchContainer.addSubview(search)
        let clearSearch = NSButton(image: NSImage(systemSymbolName: "xmark.circle",
                                                  accessibilityDescription: L10n.text("검색 지우기"))!,
                                   target: self, action: #selector(clearNavigationSearch))
        clearSearch.image = clearSearch.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        clearSearch.isBordered = false
        clearSearch.bezelStyle = .regularSquare
        clearSearch.contentTintColor = .secondaryLabelColor
        clearSearch.frame = NSRect(x: 163, y: 7, width: 18, height: 18)
        clearSearch.isHidden = true
        clearSearch.setAccessibilityLabel(L10n.text("검색 지우기"))
        searchContainer.addSubview(clearSearch)
        navigationSearchField = search
        navigationSearchContainer = searchContainer
        navigationClearButton = clearSearch
        root.addSubview(searchContainer)
        let divider = NSBox(frame: NSRect(x: 210, y: 0, width: 1, height: 600))
        divider.boxType = .separator
        root.addSubview(divider)

        let categories = [("일반", "gearshape"), ("AI 표시", "sparkles"), ("알림", "bell")]
        var notificationDocument: NSView?
        let notificationDocumentHeight: CGFloat = 840
        for (index, category) in categories.enumerated() {
            // Place the icon and title explicitly. NSButton's default image
            // layout uses a very small leading inset and varies by symbol.
            let button = NSButton(title: "", target: self, action: #selector(selectPage(_:)))
            let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let icon = NSImageView(frame: NSRect(x: 10, y: 9, width: 18, height: 18))
            icon.image = NSImage(systemSymbolName: category.1, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfiguration)
            icon.imageScaling = .scaleProportionallyDown
            icon.contentTintColor = .labelColor
            icon.setAccessibilityElement(false)
            button.addSubview(icon)
            let title = NSTextField(labelWithString: L10n.text(category.0))
            title.font = .systemFont(ofSize: 13)
            title.textColor = .labelColor
            // Keep the label's drawing frame the same height as the icon so
            // NSTextField's default baseline cannot pin the glyphs to the row top.
            title.frame = NSRect(x: 35, y: 9, width: 110, height: 18)
            title.setAccessibilityElement(false)
            button.addSubview(title)
            localizedFields.append((field: title, key: category.0))
            button.setAccessibilityLabel(L10n.text(category.0))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.frame = NSRect(x: 8, y: 289 - index * 38, width: 194, height: 36)
            button.tag = index
            navigationKeys.append(category.0)
            navigationTitles.append(L10n.text(category.0))
            root.addSubview(button)
            navigation.append(button)

            // Keep all pages alive so background account-status updates are preserved.
            let page = NSView(frame: NSRect(x: 211, y: 0, width: 469, height: 600))
            root.addSubview(page)
            pages.append(page)
            if index == 2 {
                let scroll = NSScrollView(frame: page.bounds)
                scroll.borderType = .noBorder
                scroll.drawsBackground = false
                scroll.hasHorizontalScroller = false
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = false
                scroll.scrollerStyle = .overlay
                // Keep the initial notification-page position as a hard
                // upper bound. Elastic scrolling otherwise lets the document
                // move above the title and creates an artificial top gap.
                scroll.verticalScrollElasticity = .none
                scroll.contentView = NotificationClipView()

                let document = NotificationDocumentView(frame: NSRect(x: 0, y: 0,
                                                                        width: page.bounds.width,
                                                                        height: notificationDocumentHeight))
                document.autoresizingMask = [.width]
                scroll.documentView = document
                page.addSubview(scroll)
                notificationDocument = document
                notificationScrollView = scroll
            } else {
                label(category.0, in: page, x: 13, y: 389, width: 437, size: 18, bold: true)
            }
        }

        let searchDefinitions: [(categoryIndex: Int, parentKey: String,
                                 iconName: String, children: [String])] = [
            (0, "일반", "gearshape", [
                "언어", "로그인 시 PlusCodex 자동 실행"
            ]),
            (1, "AI 표시", "sparkles", [
                "AI 서비스", "사용량 표시", "사용한 양으로 표시하기"
            ]),
            (2, "알림", "bell", [
                "알림 설정", "알림 소리", "재생 시간", "음량", "알림 테스트", "테스트 알림을 발송합니다.", "알림 항목", "작업 완료", "사용량 부족",
                "사용량 초기화", "업데이트", "승인 요청", "답변 요청", "MCP 확인 요청", "앱 승인 요청", "작업 실패"
            ])
        ]
        var searchRowY: CGFloat = 289
        func addNavigationSearchRow(titleKey: String, categoryIndex: Int,
                                    iconName: String?, isParent: Bool) {
            let row = NSButton(title: "", target: self,
                               action: #selector(selectNavigationSearchResult(_:)))
            row.bezelStyle = .regularSquare
            row.isBordered = false
            row.wantsLayer = true
            row.layer?.cornerRadius = 9
            row.frame = NSRect(x: 8, y: searchRowY, width: 194, height: 36)
            row.tag = categoryIndex

            if let iconName {
                let icon = NSImageView(frame: NSRect(x: 10, y: 9, width: 18, height: 18))
                icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16,
                                                                          weight: .regular))
                icon.imageScaling = .scaleProportionallyDown
                icon.contentTintColor = .secondaryLabelColor
                icon.setAccessibilityElement(false)
                row.addSubview(icon)
            }

            let title = NSTextField(labelWithString: L10n.text(titleKey))
            title.font = .systemFont(ofSize: 13)
            title.textColor = .labelColor
            title.frame = NSRect(x: 35, y: 9, width: 150, height: 18)
            title.setAccessibilityElement(false)
            row.addSubview(title)
            localizedFields.append((field: title, key: titleKey))
            row.setAccessibilityLabel(L10n.text(titleKey))
            row.isHidden = true
            root.addSubview(row)
            navigationSearchRows.append((button: row, categoryIndex: categoryIndex,
                                         titleKey: titleKey, isParent: isParent))
            searchRowY -= 38
        }
        for definition in searchDefinitions {
            addNavigationSearchRow(titleKey: definition.parentKey,
                                   categoryIndex: definition.categoryIndex,
                                   iconName: definition.iconName, isParent: true)
            for child in definition.children {
                addNavigationSearchRow(titleKey: child,
                                       categoryIndex: definition.categoryIndex,
                                       iconName: nil, isParent: false)
            }
        }
        let navigationEmpty = NSTextField(labelWithString: L10n.text("결과를 찾을 수 없습니다"))
        navigationEmpty.font = .systemFont(ofSize: 13)
        navigationEmpty.textColor = .secondaryLabelColor
        navigationEmpty.frame = NSRect(x: 14, y: 289, width: 180, height: 24)
        navigationEmpty.isHidden = true
        navigationEmpty.setAccessibilityElement(false)
        root.addSubview(navigationEmpty)
        localizedFields.append((field: navigationEmpty, key: "결과를 찾을 수 없습니다"))
        navigationEmptyState = navigationEmpty
        let general = pages[0]
        label("기본 설정", in: general, x: 13, y: 347, width: 437, size: 14, bold: true)
        let generalCard = NSView(frame: NSRect(x: 13, y: 189, width: 437, height: 150))
        generalCard.wantsLayer = true
        generalCard.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        generalCard.layer?.cornerRadius = 12
        generalCard.layer?.borderWidth = 1
        generalCard.layer?.borderColor = NSColor.separatorColor.cgColor
        generalCard.layer?.masksToBounds = true
        general.addSubview(generalCard)

        func cardSeparator(_ card: NSView, y: CGFloat) {
            let line = NSBox(frame: NSRect(x: 16, y: y, width: card.bounds.width - 32, height: 1))
            line.boxType = .separator
            card.addSubview(line)
        }

        let cardSeparatorY: CGFloat = 78
        let rowInset: CGFloat = 12
        // NSTextField's glyphs sit inside their frames with asymmetric
        // baseline padding. Lower the language group so the visible top and
        // bottom whitespace, not only the frame coordinates, matches.
        let languageVerticalOffset: CGFloat = 5
        cardSeparator(generalCard, y: cardSeparatorY)
        label("언어", in: generalCard, x: 16, y: 114 - languageVerticalOffset,
              width: 300, size: 13, bold: true)
        label("앱 UI 언어", in: generalCard,
              x: 16, y: cardSeparatorY + rowInset - languageVerticalOffset,
              width: 315, size: 11, secondary: true)
        languagePicker.displayTitle = L10n.text("한국어")
        languagePicker.contentTintColor = .labelColor
        languagePicker.wantsLayer = true
        languagePicker.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        languagePicker.layer?.cornerRadius = 13
        languagePicker.layer?.borderWidth = 1
        languagePicker.layer?.borderColor = NSColor.separatorColor.cgColor
        // Center the picker against the complete title-and-description group.
        languagePicker.frame = NSRect(x: 343, y: 101 - languageVerticalOffset, width: 78, height: 26)
        languagePicker.identifier = NSUserInterfaceItemIdentifier("appLanguage")
        languagePicker.setAccessibilityLabel(L10n.text("언어"))
        languagePicker.target = self
        languagePicker.action = #selector(showLanguagePicker(_:))
        generalCard.addSubview(languagePicker)
        updateLanguagePickerFrame()
        configureLanguagePopover()

        label("로그인 시 PlusCodex 자동 실행", in: generalCard,
              x: 16, y: 38, width: 350, size: 13, bold: true)
        // The status label has a shorter text frame than the title label.
        // Raise it slightly so the visible glyph gap matches the language row.
        status(loginStatus, in: generalCard, y: 20, width: 350)
        loginStatus.font = .systemFont(ofSize: 11)
        // Keep the switch aligned with the two-line setting group, not only
        // with the secondary status line.
        placeSwitch(loginToggle, in: generalCard, centerY: 41)
        loginToggle.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin(_:))
        loginToggle.setAccessibilityLabel(L10n.text("로그인 시 PlusCodex 자동 실행"))

        let ai = pages[1]
        label("AI 서비스", in: ai, x: 13, y: 347, width: 437, size: 14, bold: true)
        // Match each provider row to the 78pt setting row used by General.
        let providerRowHeight: CGFloat = 78
        let providerCount = AIProvider.allCases.count
        let providerCardHeight = providerRowHeight * CGFloat(providerCount)
        let providerCardTop: CGFloat = 339
        let providerCard = NSView(frame: NSRect(x: 13,
                                                y: providerCardTop - providerCardHeight,
                                                width: 437,
                                                height: providerCardHeight))
        providerCard.wantsLayer = true
        providerCard.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        providerCard.layer?.cornerRadius = 12
        providerCard.layer?.borderWidth = 1
        providerCard.layer?.borderColor = NSColor.separatorColor.cgColor
        providerCard.layer?.masksToBounds = true
        ai.addSubview(providerCard)

        let providerRowCenterOffset: CGFloat = 41
        let firstProviderCenterY = providerRowCenterOffset
            + providerRowHeight * CGFloat(max(0, providerCount - 1))
        for (index, provider) in AIProvider.allCases.enumerated() {
            let centerY = firstProviderCenterY - providerRowHeight * CGFloat(index)
            let icon = NSImageView(frame: NSRect(x: 16, y: centerY - 10, width: 20, height: 20))
            icon.image = CodexStatusIcon.image(size: 22, offline: false, provider: provider)
            providerCard.addSubview(icon)
            label(provider.name, in: providerCard, x: 52, y: centerY - 3,
                  width: 350, size: 13, bold: true, localized: false)
            let field = NSTextField(labelWithString: settings.enabled(provider) ? L10n.text("연결 확인 중") : L10n.text("메뉴바에서 꺼짐"))
            status(field, in: providerCard, y: centerY - 21, width: 350)
            field.font = .systemFont(ofSize: 11)
            field.frame.origin.x = 52
            statuses[provider] = field
            let toggle = NSSwitch()
            placeSwitch(toggle, in: providerCard, centerY: centerY)
            toggle.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
            toggle.target = self
            toggle.action = #selector(toggled(_:))
            toggle.setAccessibilityLabel(L10n.text("%@ 메뉴바에 표시", provider.name))
            toggles[provider] = toggle
            if index < providerCount - 1 {
                cardSeparator(providerCard, y: centerY - providerRowCenterOffset)
            }
        }

        let usageCardHeight: CGFloat = 78
        // Leave a clear 24pt break between the provider and usage sections.
        label("사용량 표시", in: ai, x: 13, y: 57, width: 437, size: 14, bold: true)
        let usageCardTop: CGFloat = 49
        let usageCard = NSView(frame: NSRect(x: 13,
                                             y: usageCardTop - usageCardHeight,
                                             width: 437,
                                             height: usageCardHeight))
        usageCard.wantsLayer = true
        usageCard.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        usageCard.layer?.cornerRadius = 12
        usageCard.layer?.borderWidth = 1
        usageCard.layer?.borderColor = NSColor.separatorColor.cgColor
        usageCard.layer?.masksToBounds = true
        ai.addSubview(usageCard)

        label("사용한 양으로 표시하기", in: usageCard, x: 16, y: 38, width: 350, size: 13, bold: true)
        usageDisplayDescription.stringValue = L10n.text("남은 사용량 대신 사용한 사용량을 표시합니다.")
        status(usageDisplayDescription, in: usageCard, y: 20, width: 350)
        usageDisplayDescription.font = .systemFont(ofSize: 11)
        localizedFields.append((field: usageDisplayDescription,
                                key: "남은 사용량 대신 사용한 사용량을 표시합니다."))
        placeSwitch(usageDisplayToggle, in: usageCard, centerY: 41)
        usageDisplayToggle.identifier = NSUserInterfaceItemIdentifier("showUsedUsage")
        usageDisplayToggle.target = self
        usageDisplayToggle.action = #selector(toggleUsageDisplay(_:))
        usageDisplayToggle.setAccessibilityLabel(L10n.text("사용한 양으로 표시하기"))

        let notifications = notificationDocument ?? pages[2]
        let notificationRowHeight: CGFloat = 78
        // Match the top edges of the General and AI page headings.
        let notificationTitleY: CGFloat = 17
        label("알림", in: notifications, x: 13,
              y: notificationTitleY, width: 437, size: 18, bold: true)

        // Keep the permission action in the same single-row card used by the
        // General and AI pages. The button opens the system-owned permission
        // screen; the detailed switches below only control PlusCodex events.
        let permissionCardHeight: CGFloat = 390
        let permissionHeaderY: CGFloat = 59
        let permissionHeaderHeight: CGFloat = 24
        let permissionCardY = permissionHeaderY + permissionHeaderHeight + 8
        label("알림 권한", in: notifications, x: 13, y: permissionHeaderY,
              width: 437, size: 14, bold: true)
        let permissionCard = NSView(frame: NSRect(x: 13, y: permissionCardY,
                                                  width: 437, height: permissionCardHeight))
        notificationPermissionCard = permissionCard
        permissionCard.wantsLayer = true
        permissionCard.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        permissionCard.layer?.cornerRadius = 12
        permissionCard.layer?.borderWidth = 1
        permissionCard.layer?.borderColor = NSColor.separatorColor.cgColor
        permissionCard.layer?.masksToBounds = true
        notifications.addSubview(permissionCard)
        label("알림 설정", in: permissionCard, x: 16, y: 194, width: 250, size: 13, bold: true)
        status(notificationStatus, in: permissionCard, y: 176, width: 250)
        notificationStatus.font = .systemFont(ofSize: 11)
        let permissionToggle = NSSwitch()
        placeSwitch(permissionToggle, in: permissionCard, centerY: 197)
        permissionToggle.identifier = NSUserInterfaceItemIdentifier("notification-permission")
        permissionToggle.target = self
        permissionToggle.action = #selector(toggleNotificationPermission(_:))
        permissionToggle.setAccessibilityLabel(L10n.text("알림 설정"))
        notificationPermissionToggle = permissionToggle

        cardSeparator(permissionCard, y: 156)
        label("알림 소리", in: permissionCard, x: 16, y: 116, width: 220, size: 13, bold: true)
        let soundDescription = NSTextField(labelWithString: L10n.text("알림에 사용할 소리를 선택합니다."))
        status(soundDescription, in: permissionCard, y: 98, width: 250)
        soundDescription.font = .systemFont(ofSize: 11)
        localizedFields.append((field: soundDescription,
                                key: "알림에 사용할 소리를 선택합니다."))
        let soundPicker = LanguagePickerButton(frame: NSRect(x: 343, y: 106, width: 78, height: 26))
        soundPicker.contentTintColor = .labelColor
        soundPicker.wantsLayer = true
        soundPicker.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        soundPicker.layer?.cornerRadius = 13
        soundPicker.layer?.borderWidth = 1
        soundPicker.layer?.borderColor = NSColor.separatorColor.cgColor
        soundPicker.target = self
        soundPicker.action = #selector(showNotificationSoundMenu(_:))
        soundPicker.setAccessibilityLabel(L10n.text("알림 소리"))
        permissionCard.addSubview(soundPicker)
        notificationSoundPicker = soundPicker
        configureNotificationSoundPicker()

        cardSeparator(permissionCard, y: 78)
        label("재생 시간", in: permissionCard, x: 16, y: 38, width: 220, size: 13, bold: true)
        let durationDescription = NSTextField(labelWithString: L10n.text("알림 소리를 재생할 시간을 설정합니다."))
        status(durationDescription, in: permissionCard, y: 20, width: 250)
        durationDescription.font = .systemFont(ofSize: 11)
        localizedFields.append((field: durationDescription,
                                key: "알림 소리를 재생할 시간을 설정합니다."))
        notificationSoundDurationDescription = durationDescription
        let durationPicker = LanguagePickerButton(frame: NSRect(x: 343, y: 27, width: 78, height: 26))
        durationPicker.centersTitleInButton = true
        durationPicker.contentTintColor = .labelColor
        durationPicker.wantsLayer = true
        durationPicker.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        durationPicker.layer?.cornerRadius = 13
        durationPicker.layer?.borderWidth = 1
        durationPicker.layer?.borderColor = NSColor.separatorColor.cgColor
        durationPicker.target = self
        durationPicker.action = #selector(showNotificationSoundDurationMenu(_:))
        durationPicker.setAccessibilityLabel(L10n.text("재생 시간"))
        permissionCard.addSubview(durationPicker)
        notificationSoundDurationPicker = durationPicker
        configureNotificationSoundDurationPicker()

        // Existing rows stay at the top when adding controls beneath them.
        for view in permissionCard.subviews { view.frame.origin.y += 156 }
        cardSeparator(permissionCard, y: 156)
        label("음량", in: permissionCard, x: 16, y: 116, width: 180, size: 13, bold: true)
        let volumeDescription = NSTextField(labelWithString: L10n.text("사용자 지정 알림음의 음량을 조절합니다."))
        status(volumeDescription, in: permissionCard, y: 98, width: 240)
        volumeDescription.font = .systemFont(ofSize: 11)
        localizedFields.append((field: volumeDescription,
                                key: "사용자 지정 알림음의 음량을 조절합니다."))
        let volumeSlider = NSSlider(value: notificationSettings.soundVolume * 100,
                                    minValue: 0, maxValue: 100,
                                    target: self, action: #selector(changeSoundVolume(_:)))
        volumeSlider.frame = NSRect(x: 280, y: 112, width: 90, height: 24)
        volumeSlider.isContinuous = false
        volumeSlider.setAccessibilityLabel(L10n.text("음량"))
        permissionCard.addSubview(volumeSlider)
        soundVolumeSlider = volumeSlider
        let volumeLabel = NSTextField(labelWithString: "")
        volumeLabel.frame = NSRect(x: 374, y: 115, width: 47, height: 20)
        volumeLabel.alignment = .right
        permissionCard.addSubview(volumeLabel)
        soundVolumeLabel = volumeLabel
        cardSeparator(permissionCard, y: 78)
        label("알림 테스트", in: permissionCard, x: 16, y: 38, width: 180, size: 13, bold: true)
        let soundTestDescription = NSTextField(labelWithString: L10n.text("테스트 알림을 발송합니다."))
        status(soundTestDescription, in: permissionCard, y: 20, width: 240)
        soundTestDescription.font = .systemFont(ofSize: 11)
        localizedFields.append((field: soundTestDescription,
                                key: "테스트 알림을 발송합니다."))
        let testButton = PressFeedbackButton(title: L10n.text("알림 테스트"), target: self,
                                             action: #selector(sendSoundTestNotification(_:)))
        testButton.isBordered = false
        testButton.wantsLayer = true
        testButton.layer?.backgroundColor = NSColor.white.cgColor
        testButton.layer?.cornerRadius = 8
        testButton.layer?.borderWidth = 1
        testButton.layer?.borderColor = NSColor.separatorColor.cgColor
        testButton.contentTintColor = NSColor.labelColor
        let testRowCenterY: CGFloat = 41
        testButton.frame = NSRect(x: 296, y: testRowCenterY - 13, width: 125, height: 26)
        permissionCard.addSubview(testButton)
        soundTestButton = testButton
        configureNotificationSoundDurationPicker()

        let optionCount = NotificationKind.allCases.count
        // Keep notification rows inside the scrollable settings canvas.
        // Additional rows use a slightly denser rhythm; titles and
        // descriptions retain the same internal alignment as the other rows.
        let optionRowHeight: CGFloat = optionCount > 4 ? 70 : notificationRowHeight
        let optionCardHeight = optionRowHeight * CGFloat(optionCount)
        let optionHeaderY = permissionCardY + permissionCardHeight + 21
        let optionHeaderHeight: CGFloat = 24
        let optionCardTop = optionHeaderY + optionHeaderHeight
        let optionHeader = label("알림 항목", in: notifications, x: 13, y: optionHeaderY,
                                 width: 437, size: 14, bold: true)
        notificationOptionsHeader = optionHeader
        let optionCard = NSView(frame: NSRect(x: 13, y: optionCardTop,
                                              width: 437, height: optionCardHeight))
        optionCard.wantsLayer = true
        optionCard.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        optionCard.layer?.cornerRadius = 12
        optionCard.layer?.borderWidth = 1
        optionCard.layer?.borderColor = NSColor.separatorColor.cgColor
        optionCard.layer?.masksToBounds = true
        notifications.addSubview(optionCard)
        notificationOptionsCard = optionCard

        let optionCenterOffset: CGFloat = optionRowHeight == notificationRowHeight ? 41 : 35
        let firstOptionCenterY = optionCenterOffset
            + optionRowHeight * CGFloat(max(0, optionCount - 1))
        for (index, kind) in NotificationKind.allCases.enumerated() {
            let centerY = firstOptionCenterY - optionRowHeight * CGFloat(index)
            label(kind.titleKey, in: optionCard, x: 16, y: centerY - 3,
                  width: 350, size: 13, bold: true)
            let description = NSTextField(labelWithString: L10n.text(kind.descriptionKey))
            status(description, in: optionCard, y: centerY - 21, width: 350)
            description.font = .systemFont(ofSize: 11)
            localizedFields.append((field: description, key: kind.descriptionKey))

            let toggle = NSSwitch()
            placeSwitch(toggle, in: optionCard, centerY: centerY)
            toggle.identifier = NSUserInterfaceItemIdentifier("notification-\(kind.rawValue)")
            toggle.target = self
            toggle.action = #selector(toggleNotification(_:))
            toggle.setAccessibilityLabel(L10n.text(kind.titleKey))
            notificationToggles[kind] = toggle
            if index < optionCount - 1 {
                cardSeparator(optionCard, y: centerY - optionCenterOffset)
            }
        }
        // The reference layout uses a taller canvas. Keep the app compact at
        // 720 points wide while preserving the same top spacing proportion.
        let verticalOffset: CGFloat = 170
        for view in root.subviews where view !== divider && !pages.contains(where: { $0 === view }) {
            view.frame.origin.y += verticalOffset
        }
        for (index, page) in pages.enumerated() {
            page.frame.size.height = root.bounds.height
            // The notification page owns its own taller document view. Its
            // scroll viewport must stay fixed while the document scrolls.
            if index != 2 {
                for view in page.subviews { view.frame.origin.y += verticalOffset }
            }
        }
        let footerColor = NSColor.labelColor.withAlphaComponent(0.35)
        let footerFont = NSFont.systemFont(ofSize: 10)
        let releaseTitle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let separatorTitle = "|"
        let makerTitle = "Copyright 2026 hyxx-su"
        let releaseWidth = ceil((releaseTitle as NSString).size(withAttributes: [.font: footerFont]).width)
        let separatorWidth = ceil((separatorTitle as NSString).size(withAttributes: [.font: footerFont]).width)
        let makerWidth = ceil((makerTitle as NSString).size(withAttributes: [.font: footerFont]).width)
        let footerGap: CGFloat = 5
        let footerWidth = releaseWidth + separatorWidth + makerWidth + footerGap * 2
        let footerX = (210 - footerWidth) / 2
        let release = FooterLinkLabel(labelWithString: releaseTitle)
        release.font = footerFont
        release.textColor = footerColor
        release.isBezeled = false
        release.drawsBackground = false
        release.isEditable = false
        release.isSelectable = false
        release.alignment = .left
        release.frame = NSRect(x: footerX, y: 14, width: releaseWidth, height: 18)
        release.toolTip = "https://github.com/hyxx-su/PlusCodex/releases/latest"
        release.setAccessibilityLabel(L10n.text("릴리즈 보기"))
        release.onClick = { [weak self] in self?.openReleasePage() }
        root.addSubview(release)
        releaseButton = release

        let separator = CenteredTitleLabel(labelWithString: separatorTitle)
        separator.font = footerFont
        separator.textColor = footerColor
        separator.alignment = .left
        separator.frame = NSRect(x: footerX + releaseWidth + footerGap,
                                 y: 14, width: separatorWidth, height: 18)
        root.addSubview(separator)

        let maker = FooterLinkLabel(labelWithString: makerTitle)
        maker.font = footerFont
        maker.textColor = footerColor
        maker.isBezeled = false
        maker.drawsBackground = false
        maker.isEditable = false
        maker.isSelectable = false
        maker.alignment = .left
        maker.frame = NSRect(x: footerX + releaseWidth + footerGap + separatorWidth + footerGap,
                             y: 14, width: makerWidth, height: 18)
        maker.toolTip = "https://github.com/hyxx-su"
        maker.setAccessibilityLabel(L10n.text("내 GitHub 계정"))
        maker.onClick = { [weak self] in self?.openMakerPage() }
        root.addSubview(maker)
        makerButton = maker
        divider.frame = NSRect(x: 210, y: 0, width: 1, height: root.bounds.height)
        prepareNotificationSoundLayout()
        showPage(0)
        synchronize()
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = languagePopoverEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        notificationSoundPopover?.close()
    }

    func windowWillClose(_ notification: Notification) {
        closeLanguagePopover()
        notificationSoundPopover?.close()
        notificationStyleGuidancePopover?.close()
        cancelSoundTestNotification()
    }

    @objc private func languageDidChange() { reloadLocalization() }

    /// Refresh controls that were created from localized strings. The data
    /// and provider state remain untouched; only presentation text changes.
    func reloadLocalization() {
        notificationSoundPopover?.close()
        notificationStyleGuidancePopover?.close()
        window?.title = L10n.text("설정")
        closeButton?.setAccessibilityLabel(L10n.text("닫기"))
        releaseButton?.setAccessibilityLabel(L10n.text("릴리즈 보기"))
        makerButton?.setAccessibilityLabel(L10n.text("내 GitHub 계정"))
        navigationSearchField?.placeholderString = L10n.text("설정 검색")
        navigationSearchField?.setAccessibilityLabel(L10n.text("설정 검색"))
        navigationClearButton?.setAccessibilityLabel(L10n.text("검색 지우기"))
        for entry in localizedFields {
            let value = L10n.text(entry.key)
            entry.field.stringValue = value
        }
        navigationTitles = navigationKeys.map { L10n.text($0) }
        for (index, button) in navigation.enumerated() {
            button.setAccessibilityLabel(L10n.text(navigationKeys[index]))
        }
        languagePicker.setAccessibilityLabel(L10n.text("언어"))
        languageSearchField?.placeholderString = L10n.text("언어 검색")
        languageSearchField?.setAccessibilityLabel(L10n.text("언어 검색"))
        for (index, option) in languageOptions.enumerated() {
            option.setDisplayTitle(index == 0 ? L10n.text("한국어") : L10n.text("English"))
        }
        languageEmptyState?.stringValue = L10n.text("결과를 찾을 수 없습니다")
        if let search = languageSearchField { filterLanguages(search) }
        notificationStatus.stringValue = L10n.text("앱의 알림을 받습니다.")
        notificationPermissionToggle?.setAccessibilityLabel(L10n.text("알림 설정"))
        notificationSoundPicker?.setAccessibilityLabel(L10n.text("알림 소리"))
        notificationSoundDurationPicker?.setAccessibilityLabel(L10n.text("재생 시간"))
        configureNotificationSoundPicker()
        configureNotificationSoundDurationPicker()
        for kind in NotificationKind.allCases {
            notificationToggles[kind]?.setAccessibilityLabel(L10n.text(kind.titleKey))
        }
        loginToggle.setAccessibilityLabel(L10n.text("로그인 시 PlusCodex 자동 실행"))
        usageDisplayToggle.setAccessibilityLabel(L10n.text("사용한 양으로 표시하기"))
        for provider in AIProvider.allCases {
            toggles[provider]?.setAccessibilityLabel(L10n.text("%@ 메뉴바에 표시", provider.name))
        }
        if let search = navigationSearchField { filterNavigation(search) }
        refreshNotifications()
        synchronize()
    }
    private func showPage(_ index: Int) {
        let wasVisible = pages[index].isHidden == false
        for (offset, page) in pages.enumerated() {
            page.isHidden = offset != index
            navigation[offset].layer?.backgroundColor = offset == index
                ? NSColor.labelColor.withAlphaComponent(0.05).cgColor : NSColor.clear.cgColor
            navigation[offset].setAccessibilityValue(offset == index ? 1 : 0)
        }
        if index == 2 && !wasVisible {
            scrollNotificationsToTop()
        }
    }
    private func scrollNotificationsToTop() {
        guard let scroll = notificationScrollView else { return }
        // The document is flipped, so y = 0 is the fixed entry position.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func clampNotificationScrollPosition() {
        guard let scroll = notificationScrollView else { return }
        scroll.contentView.scroll(to: scroll.contentView.bounds.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func selectPage(_ sender: NSButton) { showPage(sender.tag) }
    @objc private func selectNavigationSearchResult(_ sender: NSButton) {
        showPage(sender.tag)
        guard let row = navigationSearchRows.first(where: { $0.button === sender }),
              row.titleKey == "언어" else { return }

        // General settings are shown in one compact page. Make the language
        // control the focused target so selecting the child result lands on
        // the actual language setting instead of only changing the category.
        window?.makeFirstResponder(languagePicker)
    }
    private func restoreNavigationMenu() {
        for button in navigation {
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = true
        }
    }
    @objc private func filterNavigation(_ sender: NSTextField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isSearching = !query.isEmpty

        // Keep the search field's appearance stable. Only its clear button
        // and result list change while the user types.
        navigationSearchContainer?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        navigationSearchContainer?.layer?.borderWidth = 1
        navigationClearButton?.isHidden = !isSearching
        sender.frame.size.width = isSearching ? 118 : 146

        if isSearching {
            for button in navigation {
                button.isHidden = true
                button.alphaValue = 0
                button.isEnabled = false
            }
        } else {
            restoreNavigationMenu()
        }

        guard isSearching else {
            for row in navigationSearchRows { row.button.isHidden = true }
            navigationEmptyState?.isHidden = true
            // Text-field changes and button actions can arrive in either
            // order on AppKit. Re-apply the empty state on the next run-loop
            // turn so the original sidebar cannot remain hidden.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.navigationSearchField?.stringValue
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
                    return
                }
                self.restoreNavigationMenu()
            }
            return
        }

        var matchingChildren = Set<Int>()
        for row in navigationSearchRows where !row.isParent {
            if L10n.text(row.titleKey).lowercased().contains(query) {
                matchingChildren.insert(row.categoryIndex)
            }
        }

        for row in navigationSearchRows {
            let matches = row.isParent
                ? navigationTitles[row.categoryIndex].lowercased().contains(query)
                    || matchingChildren.contains(row.categoryIndex)
                : L10n.text(row.titleKey).lowercased().contains(query)
            row.button.isHidden = !matches
        }

        let rowYStart = (navigationSearchContainer?.frame.minY ?? 335) - 44
        var rowY = rowYStart
        var visibleRowCount = 0
        for row in navigationSearchRows where !row.button.isHidden {
            row.button.frame.origin.y = rowY
            rowY -= 38
            visibleRowCount += 1
        }
        navigationEmptyState?.frame.origin.y = rowYStart + 4
        navigationEmptyState?.isHidden = visibleRowCount > 0
    }
    @objc private func clearNavigationSearch() {
        guard let search = navigationSearchField else { return }
        search.stringValue = ""
        filterNavigation(search)
        window?.makeFirstResponder(search)
    }
    private func resetNavigationSearch() {
        guard let search = navigationSearchField else { return }
        search.stringValue = ""
        filterNavigation(search)
    }
    @objc private func returnToApp() {
        resetNavigationSearch()
        close()
    }
    @objc private func openReleasePage() {
        guard let url = URL(string: "https://github.com/hyxx-su/PlusCodex/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openMakerPage() {
        guard let url = URL(string: "https://github.com/hyxx-su") else { return }
        NSWorkspace.shared.open(url)
    }
    func present() {
        resetNavigationSearch()
        synchronize(); refreshNotifications(); NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        scrollNotificationsToTop()
    }
    func windowDidBecomeKey(_ notification: Notification) { synchronize(); refreshNotifications() }
    func synchronize() {
        let remainingValues = AIProvider.allCases.map { settings.showRemaining($0) }
        usageDisplayToggle.state = remainingValues.allSatisfy({ !$0 }) ? .on : .off
        languagePicker.displayTitle = language.selected == .korean ? L10n.text("한국어") : "English"
        updateLanguagePickerFrame()
        for (index, option) in languageOptions.enumerated() {
            let selected = option.tag == (language.selected == .korean ? 0 : 1)
            option.isSelectedOption = selected
            if index < languageCheckmarks.count {
                languageCheckmarks[index].isHidden = !selected
            }
        }
        for provider in AIProvider.allCases {
            toggles[provider]?.state = settings.enabled(provider) ? .on : .off
            statuses[provider]?.alphaValue = settings.enabled(provider) ? 1 : 0.5
        }
        loginToggle.state = login.requested ? .on : .off
        for kind in NotificationKind.allCases {
            notificationToggles[kind]?.state = notificationSettings.isEnabled(kind) ? .on : .off
        }
        configureNotificationSoundPicker()
        configureNotificationSoundDurationPicker()
        // Keep the setting description stable. Approval and failure guidance
        // is handled separately when the login-item request is made.
        loginStatus.stringValue = L10n.text("Mac에 로그인할 때 PlusCodex를 실행합니다.")
    }
    private func updateLanguagePickerFrame() {
        guard let parent = languagePicker.superview else { return }
        let rightInset: CGFloat = 16
        let width = languagePicker.preferredWidth
        let height = languagePicker.frame.height > 0 ? languagePicker.frame.height : 26
        languagePicker.frame = NSRect(x: parent.bounds.width - rightInset - width,
                                      y: languagePicker.frame.minY,
                                      width: width,
                                      height: height)
    }
    func update(_ provider: AIProvider, status: String) {
        statuses[provider]?.stringValue = status
    }
    private func configureLanguagePopover() {
        let contentWidth: CGFloat = 240
        let rowHeight: CGFloat = 30
        let maxVisibleRows = 8
        let totalRowCount = max(1, AppLanguage.allCases.count)
        let visibleRowCount = min(totalRowCount, maxVisibleRows)
        let listHeight = rowHeight * CGFloat(visibleRowCount)
        let headerHeight: CGFloat = 45
        let bottomInset: CGFloat = 8
        let listTopInset: CGFloat = 8
        let contentHeight = headerHeight + listHeight + bottomInset + listTopInset
        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.cornerRadius = 13
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor

        let searchIcon = NSImageView(frame: NSRect(x: 13, y: contentHeight - 30, width: 15, height: 15))
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.contentTintColor = .secondaryLabelColor
        content.addSubview(searchIcon)

        let search = NSTextField(frame: NSRect(x: 35, y: contentHeight - 38,
                                               width: contentWidth - 50, height: 24))
        search.placeholderString = L10n.text("언어 검색")
        search.font = .systemFont(ofSize: 12.5)
        search.isBezeled = false
        search.isEditable = true
        search.isSelectable = true
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        search.target = self
        search.action = #selector(filterLanguages(_:))
        search.setAccessibilityLabel(L10n.text("언어 검색"))
        content.addSubview(search)
        languageSearchField = search

        let separator = NSBox(frame: NSRect(x: 10, y: contentHeight - headerHeight,
                                            width: contentWidth - 20, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        let scroll = NSScrollView(frame: NSRect(x: 4, y: bottomInset,
                                                width: contentWidth - 8, height: listHeight))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = totalRowCount > maxVisibleRows
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.usesPredominantAxisScrolling = true

        let documentHeight = max(rowHeight * 2, rowHeight * CGFloat(AppLanguage.allCases.count))
        // Match the document view to the scroll viewport so option rows keep
        // equal white margins on both sides of the panel.
        let documentWidth = contentWidth - 8
        let document = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight))
        document.postsFrameChangedNotifications = false
        for (index, title) in [L10n.text("한국어"), "English"].enumerated() {
            let option = LanguageOptionButton(title: title, target: self, action: #selector(selectLanguage(_:)))
            option.tag = index
            option.alignment = .left
            option.isBordered = false
            option.contentTintColor = .labelColor
            option.wantsLayer = true
            option.layer?.cornerRadius = 8
            let rowInset: CGFloat = 8
            let optionWidth = documentWidth - rowInset * 2
            option.frame = NSRect(x: rowInset,
                                  y: documentHeight - rowHeight * CGFloat(index + 1),
                                  width: optionWidth, height: rowHeight)
            option.setDisplayTitle(title)
            option.configureTitleLabel(width: optionWidth)
            document.addSubview(option)
            languageOptions.append(option)

            let checkmark = NSImageView(frame: NSRect(x: optionWidth - 21, y: 8, width: 14, height: 14))
            checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            checkmark.imageScaling = .scaleProportionallyDown
            checkmark.contentTintColor = .secondaryLabelColor
            checkmark.isHidden = true
            checkmark.setAccessibilityElement(false)
            option.addSubview(checkmark)
            languageCheckmarks.append(checkmark)
        }
        let emptyState = NSTextField(labelWithString: L10n.text("결과를 찾을 수 없습니다"))
        emptyState.alignment = .center
        emptyState.font = .systemFont(ofSize: 12)
        emptyState.textColor = .secondaryLabelColor
        emptyState.frame = NSRect(x: 0, y: 18, width: documentWidth, height: 24)
        emptyState.isHidden = true
        document.addSubview(emptyState)
        languageEmptyState = emptyState
        scroll.documentView = document
        content.addSubview(scroll)
        content.layer?.masksToBounds = true
        let contentSize = content.frame.size
        languagePopoverContentSize = contentSize
        languagePopover.contentView = content
        languagePopover.setContentSize(contentSize)
        content.frame = NSRect(origin: .zero, size: contentSize)
    }
    @objc private func showLanguagePicker(_ sender: NSButton) {
        if languagePopover.isVisible {
            closeLanguagePopover()
            return
        }
        notificationSoundPopover?.close()
        languageSearchField?.stringValue = ""
        if let search = languageSearchField { filterLanguages(search) }
        synchronize()
        guard let window = sender.window else { return }
        let buttonRect = sender.convert(sender.bounds, to: nil)
        let buttonScreenRect = window.convertToScreen(buttonRect)
        let panelGap: CGFloat = 4
        let panelFrame = NSRect(x: buttonScreenRect.maxX - languagePopoverContentSize.width,
                                y: buttonScreenRect.minY - languagePopoverContentSize.height - panelGap,
                                width: languagePopoverContentSize.width,
                                height: languagePopoverContentSize.height)
        languagePopover.setFrame(panelFrame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        languagePopover.orderFrontRegardless()
        languagePopover.makeKey()
        installLanguagePopoverEventMonitor()
        if let search = languageSearchField {
            languagePopover.makeFirstResponder(search)
        }
    }
    private func installLanguagePopoverEventMonitor() {
        if let monitor = languagePopoverEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        languagePopoverEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.languagePopover.isVisible else { return event }
                let location = NSEvent.mouseLocation
                let buttonRect = self.languagePicker.window.map {
                    $0.convertToScreen(self.languagePicker.convert(self.languagePicker.bounds, to: nil))
                }
                if !self.languagePopover.frame.contains(location),
                   !(buttonRect?.contains(location) ?? false) {
                    self.closeLanguagePopover()
                }
                return event
            }
    }
    private func closeLanguagePopover() {
        if let monitor = languagePopoverEventMonitor {
            NSEvent.removeMonitor(monitor)
            languagePopoverEventMonitor = nil
        }
        languagePopover.orderOut(nil)
    }
    @objc private func filterLanguages(_ sender: NSTextField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var visibleCount = 0
        for option in languageOptions {
            let visible = query.isEmpty || option.displayTitle.lowercased().contains(query)
            option.isHidden = !visible
            if visible { visibleCount += 1 }
        }
        languageEmptyState?.isHidden = visibleCount > 0
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === languageSearchField {
            filterLanguages(field)
        } else if field === navigationSearchField {
            filterNavigation(field)
        }
    }
    @objc private func selectLanguage(_ sender: NSButton) {
        language.select(sender.tag == 0 ? .korean : .english)
        closeLanguagePopover()
        synchronize()
    }
    @objc private func toggleUsageDisplay(_ sender: NSSwitch) {
        let showRemaining = sender.state != .on
        for provider in AIProvider.allCases {
            settings.setShowRemaining(showRemaining, for: provider)
        }
        synchronize()
    }
    @objc private func toggleNotification(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("notification-"),
              let kind = NotificationKind(rawValue: String(raw.dropFirst("notification-".count))) else {
            return
        }
        let enabled = sender.state == .on
        notificationSettings.setEnabled(enabled, for: kind)
        if enabled { ensureNotificationPermission() }
        synchronize()
    }
    @objc private func toggleNotificationPermission(_ sender: NSSwitch) {
        let requestedState = sender.state == .on
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] state in
            let allowed = state.authorizationStatus == .authorized || state.authorizationStatus == .provisional
            DispatchQueue.main.async {
                guard let self else { return }
                if requestedState != allowed { self.openNotifications() }
                self.refreshNotifications()
            }
        }
    }
    private func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationStatus.stringValue = L10n.text("앱의 알림을 받습니다.")
                self.notificationPermissionToggle?.state = state.authorizationStatus == .authorized || state.authorizationStatus == .provisional
                    ? .on : .off
                self.notificationAlertStyle = state.alertStyle
                self.configureNotificationSoundDurationPicker()
            }
        }
    }
    private func ensureNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] state in
            guard state.authorizationStatus != .authorized,
                  state.authorizationStatus != .provisional else { return }
            DispatchQueue.main.async { self?.openNotifications() }
        }
    }
    private func configureNotificationSoundPicker() {
        guard let picker = notificationSoundPicker else { return }
        if let displayName = notificationSettings.customSoundDisplayName {
            picker.displayTitle = L10n.text("사용자 지정: %@",
                                            SavedNotificationSound.displayTitle(for: displayName))
        } else {
            picker.displayTitle = L10n.text("기본 알림음")
        }
        updateNotificationPickerFrame(picker)
    }

    private func configureNotificationSoundDurationPicker() {
        guard let picker = notificationSoundDurationPicker else { return }
        let hasCustomSound = notificationSettings.customSoundName != nil
        let canSetDuration = hasCustomSound && notificationAlertStyle == .alert
        // Keep the control clickable so it can guide users to the required system setting.
        picker.isEnabled = hasCustomSound
        notificationSoundDurationDescription?.stringValue = L10n.text(
            hasCustomSound && !canSetDuration
                ? "지속적 알림에서만 재생 시간을 설정할 수 있습니다."
                : "알림 소리를 재생할 시간을 설정합니다."
        )
        soundVolumeSlider?.isEnabled = hasCustomSound
        soundTestButton?.setLoading(isSendingSoundTestNotification)
        soundVolumeSlider?.doubleValue = notificationSettings.soundVolume * 100
        soundVolumeLabel?.stringValue = "\(Int((notificationSettings.soundVolume * 100).rounded()))%"
        let maximum = notificationSettings.maximumSelectableSoundDuration
        let selectedDuration = min(Int(notificationSettings.soundDuration.rounded()), maximum)
        picker.displayTitle = canSetDuration
            ? L10n.text("%d초", selectedDuration)
            : L10n.text("시스템")

        let menu = NSMenu()
        menu.autoenablesItems = false
        let minimum = Int(NotificationSettings.minimumSoundDuration)
        for duration in minimum...maximum {
            let item = NSMenuItem(title: L10n.text("%d초", duration),
                                  action: #selector(selectNotificationSoundDuration(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: duration)
            item.state = duration == selectedDuration ? .on : .off
            menu.addItem(item)
        }
        notificationSoundDurationMenu = menu
        updateNotificationPickerFrame(picker)
        updateNotificationSoundLayout(animated: true)
    }

    private func prepareNotificationSoundLayout() {
        guard let card = notificationPermissionCard,
              let optionHeader = notificationOptionsHeader,
              let optionCard = notificationOptionsCard,
              let document = notificationScrollView?.documentView else { return }

        notificationTopSoundRows = card.subviews.compactMap { view in
            guard !(view is NSBox), view.frame.minY >= 234 else { return nil }
            return (view, view.frame)
        }
        notificationConditionalSoundRows = card.subviews.compactMap { view in
            guard !(view is NSBox), view.frame.minY >= 78, view.frame.minY < 234 else { return nil }
            return (view, view.frame)
        }
        let separators = card.subviews.compactMap { view -> (NSView, NSRect)? in
            guard view is NSBox else { return nil }
            return (view, view.frame)
        }
        notificationTopSeparator = separators.first { abs($0.1.minY - 312) < 1 }
        notificationConditionalSeparators = separators.filter {
            abs($0.1.minY - 234) < 1 || abs($0.1.minY - 156) < 1
        }.map { (view: $0.0, frame: $0.1) }
        notificationOptionsBaseFrames = [(optionHeader, optionHeader.frame), (optionCard, optionCard.frame)]

        notificationExpandedCardHeight = card.frame.height
        let neededDocumentHeight = max(document.superview?.bounds.height ?? 600,
                                       ceil(optionCard.frame.maxY + 24))
        document.setFrameSize(NSSize(width: document.frame.width, height: neededDocumentHeight))
        notificationExpandedDocumentHeight = neededDocumentHeight
        notificationLayoutReady = true
        updateNotificationSoundLayout(animated: false)
    }

    private func updateNotificationSoundLayout(animated: Bool) {
        guard notificationLayoutReady,
              let card = notificationPermissionCard,
              let document = notificationScrollView?.documentView else { return }
        let expanded = notificationSettings.customSoundName != nil
        guard notificationSoundLayoutExpanded != expanded else { return }
        let previousExpansion = notificationSoundLayoutExpanded
        notificationSoundLayoutExpanded = expanded
        notificationLayoutGeneration += 1
        let generation = notificationLayoutGeneration
        // Cached frames describe the expanded layout. Apply this target offset
        // to those base frames without changing the user's scroll position.
        let layoutOffset: CGFloat = expanded ? 0 : -156
        let targetCardHeight = expanded
            ? notificationExpandedCardHeight
            : max(0, notificationExpandedCardHeight - 156)
        let targetDocumentHeight = expanded
            ? notificationExpandedDocumentHeight
            : max(document.superview?.bounds.height ?? 600,
                  notificationExpandedDocumentHeight - 156)

        for entry in notificationConditionalSoundRows + notificationConditionalSeparators {
            entry.view.isHidden = false
            if expanded && previousExpansion == false { entry.view.alphaValue = 0 }
        }

        let updateFrames = {
            for entry in self.notificationTopSoundRows {
                var frame = entry.frame
                frame.origin.y += layoutOffset
                if entry.view is LanguagePickerButton {
                    frame.origin.x = entry.view.frame.minX
                    frame.size.width = entry.view.frame.width
                }
                entry.view.frame = frame
            }
            if let entry = self.notificationTopSeparator {
                var frame = entry.frame
                frame.origin.y += layoutOffset
                entry.view.frame = frame
            }
            for entry in self.notificationConditionalSoundRows + self.notificationConditionalSeparators {
                entry.view.alphaValue = expanded ? 1 : 0
            }
            for entry in self.notificationOptionsBaseFrames {
                var frame = entry.frame
                frame.origin.y += layoutOffset
                entry.view.frame = frame
            }
            card.setFrameSize(NSSize(width: card.frame.width, height: targetCardHeight))
            document.setFrameSize(NSSize(width: document.frame.width, height: targetDocumentHeight))
        }

        if animated && previousExpansion != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for entry in self.notificationTopSoundRows {
                    var frame = entry.frame
                    frame.origin.y += layoutOffset
                    if entry.view is LanguagePickerButton {
                        frame.origin.x = entry.view.frame.minX
                        frame.size.width = entry.view.frame.width
                    }
                    entry.view.animator().frame = frame
                }
                if let entry = self.notificationTopSeparator {
                    var frame = entry.frame
                    frame.origin.y += layoutOffset
                    entry.view.animator().frame = frame
                }
                for entry in self.notificationConditionalSoundRows + self.notificationConditionalSeparators {
                    entry.view.animator().alphaValue = expanded ? 1 : 0
                }
                for entry in self.notificationOptionsBaseFrames {
                    var frame = entry.frame
                    frame.origin.y += layoutOffset
                    entry.view.animator().frame = frame
                }
                var cardFrame = card.frame
                cardFrame.size.height = targetCardHeight
                card.animator().frame = cardFrame
                var documentFrame = document.frame
                documentFrame.size.height = targetDocumentHeight
                document.animator().frame = documentFrame
            } completionHandler: {
                guard self.notificationLayoutGeneration == generation else { return }
                for entry in self.notificationConditionalSoundRows + self.notificationConditionalSeparators {
                    entry.view.isHidden = !expanded
                }
                self.clampNotificationScrollPosition()
            }
        } else {
            updateFrames()
            for entry in notificationConditionalSoundRows + notificationConditionalSeparators {
                entry.view.isHidden = !expanded
            }
            clampNotificationScrollPosition()
        }
    }

    private func updateNotificationPickerFrame(_ picker: LanguagePickerButton) {
        guard let parent = picker.superview else { return }
        let rightInset: CGFloat = 16
        let width = min(max(0, parent.bounds.width - rightInset - 16), picker.preferredWidth)
        picker.frame = NSRect(x: parent.bounds.width - rightInset - width,
                              y: picker.frame.minY,
                              width: width,
                              height: picker.frame.height > 0 ? picker.frame.height : 26)
    }

    @objc private func showNotificationSoundMenu(_ sender: LanguagePickerButton) {
        if notificationSoundPopover?.isVisible == true {
            notificationSoundPopover?.close()
            return
        }
        closeLanguagePopover()
        let popover: NotificationSoundPopover
        if let existing = notificationSoundPopover {
            popover = existing
        } else {
            let created = NotificationSoundPopover()
            created.onSelectDefault = { [weak self] in
                self?.notificationSettings.clearCustomSound()
                self?.synchronize()
            }
            created.onSelectSaved = { [weak self] id in self?.selectSavedNotificationSound(id) }
            created.onAdd = { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.chooseNotificationSound() }
            }
            created.onDelete = { [weak self] id in self?.confirmDeleteNotificationSound(id) }
            notificationSoundPopover = created
            popover = created
        }
        popover.show(from: sender, sounds: notificationSettings.savedSounds,
                     selectedID: notificationSettings.selectedSavedSoundID)
    }

    @objc private func showNotificationSoundDurationMenu(_ sender: LanguagePickerButton) {
        guard notificationSettings.customSoundName != nil else { return }
        guard notificationAlertStyle == .alert else {
            showPersistentAlertStyleGuidance(from: sender)
            return
        }
        guard let menu = notificationSoundDurationMenu else { return }
        showNotificationMenu(menu, from: sender)
    }

    private func showPersistentAlertStyleGuidance(from button: NSButton) {
        guard window?.isVisible == true else { return }
        notificationStyleGuidancePopover?.close()

        let guidance = L10n.text("설정에서 알림 스타일을 ‘지속적 표시’로 변경해주세요.")
        let message = NSTextField(labelWithString: guidance)
        let guidanceFont = NSFont.systemFont(ofSize: 13)
        message.font = guidanceFont
        message.textColor = .labelColor
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        let messageWidth: CGFloat = 326
        let messageHeight = ceil((guidance as NSString).boundingRect(
            with: NSSize(width: messageWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: guidanceFont]).height) + 4
        let contentHeight = max(50, messageHeight + 24)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: contentHeight))
        message.frame = NSRect(x: 12, y: (contentHeight - messageHeight) / 2,
                               width: messageWidth, height: messageHeight)
        message.alphaValue = 0
        content.addSubview(message)

        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 350, height: contentHeight)
        popover.behavior = .transient
        popover.animates = true
        notificationStyleGuidancePopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)

        var visibleFrame = message.frame
        visibleFrame.origin.x += 8
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            message.animator().frame = visibleFrame
            message.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak popover] in
            guard let self, let popover,
                  self.notificationStyleGuidancePopover === popover,
                  popover.isShown, self.window?.isVisible == true else { return }
            var exitFrame = message.frame
            exitFrame.origin.x += 12
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                message.animator().frame = exitFrame
                message.animator().alphaValue = 0
            } completionHandler: { [weak self, weak popover] in
                guard let self, let popover,
                      self.notificationStyleGuidancePopover === popover,
                      popover.isShown, self.window?.isVisible == true else { return }
                popover.close()
                self.notificationStyleGuidancePopover = nil
                self.openNotifications()
            }
        }
    }

    private func showNotificationMenu(_ menu: NSMenu, from sender: LanguagePickerButton) {
        guard let window = sender.window else { return }

        menu.update()
        let buttonRect = sender.convert(sender.bounds, to: nil)
        let buttonScreenRect = window.convertToScreen(buttonRect)
        let menuSize = menu.size
        let menuGap: CGFloat = 4
        let menuOrigin = NSPoint(x: buttonScreenRect.maxX - menuSize.width,
                                 y: buttonScreenRect.minY - menuGap)
        // Passing nil makes the location screen-based. The menu's top-right
        // edge is aligned to the button's right edge and its top edge is
        // anchored just below the button.
        menu.popUp(positioning: nil, at: menuOrigin, in: nil)
    }

    private func selectSavedNotificationSound(_ id: String) {
        do {
            try notificationSettings.selectSavedSound(id: id)
            synchronize()
        } catch let error as NotificationSettings.SoundError {
            showNotificationSoundError(error)
        } catch {
            showNotificationSoundError(.copyFailed)
        }
    }

    private func confirmDeleteNotificationSound(_ id: String) {
        guard let sound = notificationSettings.savedSounds.first(where: { $0.id == id }),
              let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("알림 소리 삭제")
        alert.informativeText = L10n.text("저장된 알림음 \"%@\"을 삭제할까요?", sound.displayTitle)
        alert.addButton(withTitle: L10n.text("취소"))
        alert.addButton(withTitle: L10n.text("삭제"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            do {
                try self.notificationSettings.deleteSavedSound(id: id)
            } catch {
                self.showNotificationSoundError(.deleteFailed)
            }
            self.synchronize()
        }
    }

    @objc private func selectNotificationSoundDuration(_ sender: NSMenuItem) {
        guard notificationAlertStyle == .alert,
              let value = sender.representedObject as? NSNumber else { return }
        do {
            try notificationSettings.setCustomSoundDuration(value.doubleValue)
            synchronize()
        } catch let error as NotificationSettings.SoundError {
            showNotificationSoundError(error)
            synchronize()
        } catch {
            showNotificationSoundError(.copyFailed)
            synchronize()
        }
    }

    private func chooseNotificationSound() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("알림 소리 선택")
        panel.message = L10n.text("MP3, M4A, AAC, AIFF, WAV 또는 CAF 파일을 선택하세요.")
        panel.allowedContentTypes = NotificationSettings.supportedSoundExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                self?.synchronize()
                return
            }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                try self.notificationSettings.setCustomSound(from: url)
                self.synchronize()
            } catch let error as NotificationSettings.SoundError {
                self.showNotificationSoundError(error)
                self.synchronize()
            } catch {
                self.showNotificationSoundError(.copyFailed)
                self.synchronize()
            }
        }
    }
    @objc private func changeSoundVolume(_ sender: NSSlider) {
        do {
            try notificationSettings.setSoundVolume(sender.doubleValue / 100)
        } catch {
            showNotificationSoundError(.copyFailed)
        }
        synchronize()
    }

    @objc private func sendSoundTestNotification(_ sender: NSButton) {
        if isSendingSoundTestNotification {
            guard soundTestCancelUnlocked else { return }
            cancelSoundTestNotification()
            return
        }
        let requestID = "sound-test-\(UUID().uuidString)"
        activeSoundTestRequestID = requestID
        soundTestCancelUnlocked = false
        soundTestButton?.setLoading(true)
        soundTestButton?.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.activeSoundTestRequestID == requestID else { return }
            self.soundTestCancelUnlocked = true
            self.soundTestButton?.isEnabled = true
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.activeSoundTestRequestID == requestID else { return }
                guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else {
                    self.finishSoundTestNotification(requestID)
                    let alert = NSAlert()
                    alert.messageText = L10n.text("알림 권한이 필요합니다.")
                    alert.informativeText = L10n.text("시스템 설정에서 PlusCodex의 알림을 허용한 뒤 다시 테스트하세요.")
                    alert.addButton(withTitle: L10n.text("알림 설정 열기"))
                    alert.addButton(withTitle: L10n.text("취소"))
                    if alert.runModal() == .alertFirstButtonReturn { self.openNotifications() }
                    return
                }
                guard status.alertSetting == .enabled else {
                    self.finishSoundTestNotification(requestID)
                    let alert = NSAlert()
                    alert.messageText = L10n.text("알림 표시 권한이 필요합니다.")
                    alert.informativeText = L10n.text("시스템 설정에서 PlusCodex의 알림 배너를 켠 뒤 다시 테스트하세요.")
                    alert.addButton(withTitle: L10n.text("알림 설정 열기"))
                    alert.addButton(withTitle: L10n.text("취소"))
                    if alert.runModal() == .alertFirstButtonReturn { self.openNotifications() }
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = L10n.text("알림 테스트")
                content.body = L10n.text("테스트 알림입니다.")
                content.sound = self.notificationSettings.sound
                content.userInfo = ["notificationSoundTest": true]
                self.notificationAlertStyle = status.alertStyle
                self.configureNotificationSoundDurationPicker()
                self.submitSoundTestNotification(content, requestID: requestID,
                                                 alertStyle: status.alertStyle, center: center)
            }
        }
    }

    private func submitSoundTestNotification(_ content: UNMutableNotificationContent,
                                             requestID: String,
                                             alertStyle: UNAlertStyle,
                                             center: UNUserNotificationCenter) {
        guard activeSoundTestRequestID == requestID else { return }
        if let previousID = lastSoundTestRequestID {
            // Only remove the previous test; a delayed lookup must never cancel the new request.
            center.removeDeliveredNotifications(withIdentifiers: [previousID])
            center.removePendingNotificationRequests(withIdentifiers: [previousID])
        }
        lastSoundTestRequestID = requestID
        // The saved duration applies only to persistent alerts; use the existing
        // short test interval when the sound duration is controlled by the system.
        let testDuration = alertStyle == .alert && notificationSettings.customSoundName != nil
            ? notificationSettings.soundDuration : 2.0

        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.activeSoundTestRequestID == requestID else {
                    // Cancellation can race with add; clean up again after scheduling completes.
                    center.removePendingNotificationRequests(withIdentifiers: [requestID])
                    center.removeDeliveredNotifications(withIdentifiers: [requestID])
                    return
                }
                guard let error else {
                    // Dismiss this test notification when its playback interval ends.
                    DispatchQueue.main.asyncAfter(deadline: .now() + testDuration) { [weak self] in
                        self?.finishSoundTestNotification(requestID)
                    }
                    return
                }
                self.finishSoundTestNotification(requestID)
                NSLog("PlusCodex sound test notification failed: %@", error.localizedDescription)
                guard let window = self.window else { return }
                let alert = NSAlert()
                alert.messageText = L10n.text("테스트 알림을 보내지 못했습니다.")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.text("확인"))
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func finishSoundTestNotification(_ requestID: String) {
        guard activeSoundTestRequestID == requestID else { return }
        activeSoundTestRequestID = nil
        soundTestCancelUnlocked = false
        soundTestButton?.setLoading(false)
        soundTestButton?.isEnabled = true
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    private func cancelSoundTestNotification() {
        guard let requestID = activeSoundTestRequestID else { return }
        activeSoundTestRequestID = nil
        soundTestCancelUnlocked = false
        soundTestButton?.setLoading(false)
        soundTestButton?.isEnabled = true
        if lastSoundTestRequestID == requestID { lastSoundTestRequestID = nil }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }
    private func showNotificationSoundError(_ error: NotificationSettings.SoundError) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("알림 소리를 설정하지 못했습니다.")
        switch error {
        case .unsupportedFormat:
            alert.informativeText = L10n.text("MP3, M4A, AAC, AIFF, WAV 또는 CAF 파일을 선택하세요.")
        case .unreadable:
            alert.informativeText = L10n.text("선택한 파일을 읽을 수 없습니다.")
        case .invalidDuration:
            alert.informativeText = L10n.text("재생 시간은 1~10초이며 음원 길이를 넘을 수 없습니다.")
        case .copyFailed:
            alert.informativeText = L10n.text("선택한 파일을 앱의 알림 소리로 저장할 수 없습니다.")
        case .deleteFailed:
            alert.messageText = L10n.text("알림 소리를 삭제하지 못했습니다.")
            alert.informativeText = L10n.text("저장된 알림음을 삭제할 수 없습니다.")
        }
        alert.addButton(withTitle: L10n.text("확인"))
        alert.beginSheetModal(for: window)
    }
    @objc private func openNotifications() {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "\(base)?id=\(bundleID)") ?? URL(string: base)!
        NSWorkspace.shared.open(url)
    }
    @objc private func toggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let provider = AIProvider(rawValue: raw) else { return }
        settings.setEnabled(sender.state == .on, for: provider); synchronize()
    }
    @objc private func toggleLogin(_ sender: NSSwitch) {
        let enabling = sender.state == .on
        do {
            try login.setEnabled(enabling); synchronize()
            if enabling && login.requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            synchronize()
            let alert = NSAlert(); alert.messageText = L10n.text("자동 실행 설정을 변경하지 못했습니다.")
            alert.informativeText = L10n.text("응용 프로그램 폴더에 설치했는지 확인하세요.\n") + error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }
}
