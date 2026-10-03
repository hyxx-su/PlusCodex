import AppKit

@main struct QuotaLayoutChecks {
    static func main() throws {
        _ = NSApplication.shared
        let weekly = QuotaWindow(usedPercent: 30, windowDurationMins: 10080, resetsAt: nil)
        let short = QuotaWindow(usedPercent: 40, windowDurationMins: 300, resetsAt: nil)
        for plan in ["free", "plus", "pro", "pro_5x", "pro_20x"] {
            let account = CodexAccount(email: "test@example.com", planType: plan)
            let quota = Quota(primary: nil, secondary: weekly)
            let view = QuotaMenuView(quota: quota, account: account, updatedAt: nil, failure: nil)
            precondition(view.bounds.height == 150)
            precondition(quota.windows.map(\.label) == ["주간"])
            precondition(!(view.accessibilityLabel() ?? "").contains("5시간"))
            view.update(quota: Quota(primary: short, secondary: weekly), account: account, updatedAt: nil, failure: nil)
            let count = plan.hasPrefix("pro") ? 1 : 2
            precondition(view.bounds.height == 58 + CGFloat(count) * 92)
            let lastCardBottom = CGFloat(62 + (count - 1) * 92 + 84)
            precondition(view.bounds.height - lastCardBottom == 4,
                         "Keep only a small trailing inset before the activity section")
            view.update(quota: Quota(primary: nil, secondary: nil), account: account, updatedAt: nil, failure: nil)
            precondition(view.bounds.height == 124)
        }
        precondition(QuotaWindow(usedPercent: 1, windowDurationMins: 15, resetsAt: nil).label == "15분")
        let monthly = QuotaWindow(usedPercent: 40, windowDurationMins: 43200, resetsAt: 12345)
        precondition(monthly.displayLabel(planType: "free", isPrimary: true) == "1개월")
        for plan in ["pro", "pro_5x", "pro_20x", "pro-200"] {
            precondition(monthly.displayLabel(planType: plan, isPrimary: true) == "1개월",
                         "Never change the meaning of a server window to match a plan")
        }
        precondition(short.displayLabel(planType: "plus", isPrimary: true) == "5시간")
        precondition(weekly.displayLabel(planType: "free", isPrimary: false) == "주간")
        precondition(monthly.resetsAt == 12345 && monthly.remaining == 60)
        let cached = Quota(primary: short, secondary: weekly)
        let now = Date()
        precondition(QuotaMenuView.canShowPreviousUsage(cached, updatedAt: now.addingTimeInterval(-9 * 60), now: now))
        precondition(!QuotaMenuView.canShowPreviousUsage(cached, updatedAt: now.addingTimeInterval(-11 * 60), now: now))
        precondition(!QuotaMenuView.canShowPreviousUsage(cached, updatedAt: now.addingTimeInterval(60), now: now))
        precondition(!QuotaMenuView.canShowPreviousUsage(nil, updatedAt: now, now: now))
        let previous = QuotaMenuView(quota: cached, updatedAt: now.addingTimeInterval(-60),
                                     failure: "조회 시간 초과")
        precondition(!previous.showsFailureScreen && previous.bounds.height == 242)
        precondition(previous.subviews.allSatisfy { !($0 is QuotaLoadingView) })
        let expired = QuotaMenuView(quota: cached, updatedAt: now.addingTimeInterval(-11 * 60),
                                    failure: "조회 시간 초과")
        precondition(expired.showsFailureScreen)
        let claude = QuotaMenuView(quota: cached, updatedAt: now, failure: "조회 시간 초과", provider: .claude)
        precondition(!claude.showsFailureScreen && claude.bounds.height == 242,
                     "Recent Claude usage is retained during a transient lookup failure")
        let statusFrame = QuotaMenuView.cardStatusTextFrame
        precondition(statusFrame.minX > 144 && statusFrame.maxX == 223 && statusFrame.maxX < 228,
                     "Status labels must stay between the title and percentage without moving their right edge")
        precondition(statusFrame.maxY < 38, "Status labels must not overlap the progress bar")
        let statusFont = NSFont.systemFont(ofSize: 10)
        for language in AppLanguage.allCases {
            for key in ["남음", "사용됨", "이전 조회"] {
                let label = L10n.translation(key, language: language) as NSString
                let size = label.size(withAttributes: [.font: statusFont])
                precondition(size.width <= statusFrame.width && size.height <= statusFrame.height,
                             "\(language.rawValue) \(label) must fit on one line without truncation")
            }
        }
        if CommandLine.arguments.contains("--render-card-localizations") {
            try renderCardLocalizations(quota: cached)
        }
        print("PASS: missing windows, real limits on all plans, dynamic height, single-line localized status")
    }

    private static func renderCardLocalizations(quota: Quota) throws {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let appearance = NSApp.appearance
        defer {
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            NSApp.appearance = appearance
        }
        for language in AppLanguage.allCases {
            var localizedArguments = arguments
            localizedArguments["appLanguage"] = language.rawValue
            defaults.setVolatileDomain(localizedArguments, forName: UserDefaults.argumentDomain)
            for theme in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: theme)
                for mode in ["remaining", "used", "cached"] {
                    let view = QuotaMenuView(quota: quota,
                        account: CodexAccount(email: "test@example.com", planType: "plus"),
                        updatedAt: Date(), failure: mode == "cached" ? "Lookup timed out" : nil,
                        showRemaining: mode != "used")
                    let window = NSWindow(contentRect: view.bounds, styleMask: .borderless,
                                          backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: theme)
                    window.contentView = view
                    view.layoutSubtreeIfNeeded()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let image = NSImage(size: view.bounds.size)
                    image.lockFocus()
                    NSColor(calibratedWhite: theme == .aqua ? 0.98 : 0.12, alpha: 1).setFill()
                    view.bounds.fill()
                    let content = NSImage(size: view.bounds.size)
                    content.addRepresentation(bitmap)
                    content.draw(in: view.bounds)
                    image.unlockFocus()
                    let opaque = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    let path = "build/quota-layout-\(language.rawValue)-\(mode)-\(theme.rawValue).png"
                    try opaque.representation(using: .png, properties: [:])!
                        .write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
}
