import AppKit

/// Presentation-only menu content; the menu retains native refresh and quit actions.
final class QuotaMenuView: NSView {
    private var quota: Quota?
    private var account: CodexAccount?
    private var updatedAt: Date?
    private var failure: String?
    let intro: Bool
    let checkingForUpdates: Bool
    let offline: Bool
    private let provider: AIProvider
    private var headerIcon: NSImage? { CodexStatusIcon.image(size: 18, offline: false, provider: provider) }
    override var isFlipped: Bool { true }

    init(quota: Quota?, account: CodexAccount? = nil, updatedAt: Date?, failure: String?, intro: Bool = false,
         checkingForUpdates: Bool = false, offline: Bool = false, preservedHeight: CGFloat? = nil,
         provider: AIProvider = .codex) {
        self.provider = provider
        self.quota = quota
        self.account = account
        self.updatedAt = updatedAt
        self.failure = failure
        self.intro = intro
        self.checkingForUpdates = checkingForUpdates
        self.offline = offline
        super.init(frame: NSRect(x: 0, y: 0, width: 300,
            height: preservedHeight ?? Self.panelHeight(quota: quota, intro: intro)))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        // Only the first opening's intro panel carries the tiny logo loader;
        // after it expires the dashboard renders immediately, even without data.
        if intro || checkingForUpdates || offline {
            setAccessibilityLabel(checkingForUpdates ? L10n.text("업데이트 확인 중. 최신 버전인지 확인하고 있어요.") : L10n.text("사용량을 불러오는 중"))
            if offline { setAccessibilityLabel(L10n.text("네트워크 연결 없음")) }
            addSubview(QuotaLoadingView(frame: bounds, logoSize: checkingForUpdates || offline ? 40 : 28,
                                       checkingForUpdates: checkingForUpdates, offline: offline, provider: provider))
        } else {
            let windows = quota?.windows ?? []
            setAccessibilityLabel(([L10n.text("%@ 남은 사용량", provider.name)] + windows.enumerated().map { index, window in
                L10n.text("%@ %d%% 남음", provider == .codex ? window.displayLabel(planType: account?.planType, isPrimary: index == 0 && quota?.primary != nil) : window.label, window.remaining)
            } + [failure ?? ""]).joined(separator: ", "))
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(quota: Quota?, account: CodexAccount?, updatedAt: Date?, failure: String?) {
        let previousCount = self.quota?.windows.count
        self.quota = quota
        self.account = account
        self.updatedAt = updatedAt
        self.failure = failure
        guard !intro && !checkingForUpdates && !offline else { return }
        if previousCount != quota?.windows.count {
            setFrameSize(NSSize(width: 300, height: Self.panelHeight(quota: quota, intro: false)))
            needsDisplay = true
        }
        let windows = quota?.windows ?? []
        setAccessibilityLabel(([L10n.text("%@ 남은 사용량", provider.name)] + windows.enumerated().map { index, window in
            L10n.text("%@ %d%% 남음", provider == .codex ? window.displayLabel(planType: account?.planType, isPrimary: index == 0 && quota?.primary != nil) : window.label, window.remaining)
        } + [failure ?? ""]).joined(separator: ", "))
        setNeedsDisplay(NSRect(x: 116, y: 12, width: 168, height: 38))
        setNeedsDisplay(NSRect(x: 12, y: 62, width: 276, height: max(62, bounds.height - 62)))
    }

    /// Intro state: `until` is the moment the tiny logo-only panel reverts.
    static func introVisible(until deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now < deadline
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !intro && !checkingForUpdates && !offline else { return }
        if let headerIcon {
            let tintedIcon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                headerIcon.draw(in: rect)
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tintedIcon.draw(in: NSRect(x: 16, y: 15, width: 16, height: 16),
                            from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
        }
        text(provider.name, x: 38, y: 12, size: provider == .claude ? 13 : 16, weight: .bold, width: 108)
        text(L10n.text("남은 사용량"), x: 16, y: 35, size: 10, color: .secondaryLabelColor)
        text(account?.email ?? (quota == nil && failure == nil ? L10n.text("계정 정보 확인 중") : L10n.text("계정 정보 없음")), x: 152, y: 15, size: 10,
             color: .secondaryLabelColor, width: 132, height: 14, align: .right,
             lineBreak: .byTruncatingMiddle)
        text(account?.planType?.capitalized ?? "—", x: 116, y: 32, size: 10,
             weight: .medium, color: .secondaryLabelColor, width: 168, height: 14, align: .right)

        let windows = quota?.windows ?? []
        if windows.isEmpty {
            let message = failure ?? (quota == nil ? L10n.text("사용량을 확인하고 있어요.") : L10n.text("현재 계정에서 제공되는 한도 정보가 없습니다."))
            text(message, x: 16, y: 70, size: 11, color: .secondaryLabelColor, width: 268, height: 42)
        } else {
            for (index, window) in windows.enumerated() {
                card(window, title: provider == .codex ? window.displayLabel(planType: account?.planType,
                     isPrimary: index == 0 && quota?.primary != nil) : window.label, y: 62 + CGFloat(index) * 92)
            }
        }
    }

    static func panelHeight(quota: Quota?, intro: Bool) -> CGFloat {
        if intro { return 250 }
        let count = quota?.windows.count ?? 0
        return count == 0 ? 124 : 66 + CGFloat(count) * 92
    }

    private func card(_ window: QuotaWindow?, title: String, y: CGFloat) {
        let rect = NSRect(x: 12, y: y, width: 276, height: 84)
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
        NSColor.labelColor.withAlphaComponent(0.07).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 13.5, yRadius: 13.5)
        border.lineWidth = 1
        border.stroke()
        let stale = failure != nil
        let remaining = window?.remaining
        let tint: NSColor = stale || remaining == nil ? .secondaryLabelColor : .labelColor
        text(title, x: 24, y: y + 11, size: 12, weight: .semibold, width: 120)
        text(stale ? L10n.text("이전 조회") : L10n.text("남음"), x: 180, y: y + 14, size: 10, color: .secondaryLabelColor,
             width: 43, align: .right)
        text(remaining.map { "\($0)%" } ?? "--%", x: 228, y: y + 10, size: 15, weight: .medium,
             color: tint, width: 48, align: .right, numeric: true)
        let track = NSRect(x: 24, y: y + 38, width: 252, height: 6)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4.5, yRadius: 4.5).fill()
        if let remaining, remaining > 0 {
            let fill = NSRect(x: track.minX, y: track.minY,
                              width: track.width * CGFloat(remaining) / 100, height: track.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: track, xRadius: 4.5, yRadius: 4.5).addClip()
            tint.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 4.5, yRadius: 4.5).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let reset = window?.resetsAt.map { timestamp -> String in
            let date = Date(timeIntervalSince1970: timestamp)
            let day = Calendar.current.isDateInToday(date) ? L10n.text("오늘") : date.formatted(.dateTime.month().day().locale(L10n.locale))
            let time = date.formatted(.dateTime.hour().minute().locale(L10n.locale))
            return L10n.text("%@ 초기화", "\(day) \(time)")
        } ?? window?.resetDescription.map { L10n.text("초기화: %@", $0) } ?? L10n.text("한도 정보 대기 중")
        text(reset, x: 24, y: y + 57, size: 10, color: .secondaryLabelColor, width: 252, height: 18)
    }

    private func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                      width: CGFloat = 190, height: CGFloat = 32, align: NSTextAlignment = .left,
                      numeric: Bool = false, lineBreak: NSLineBreakMode = .byWordWrapping) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = lineBreak
        (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: [
            .font: numeric ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: style
        ])
    }
}
