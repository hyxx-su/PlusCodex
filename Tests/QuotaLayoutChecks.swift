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
            precondition(view.bounds.height == 158)
            precondition(quota.windows.map(\.label) == ["주간"])
            precondition(!(view.accessibilityLabel() ?? "").contains("5시간"))
            view.update(quota: Quota(primary: short, secondary: weekly), account: account, updatedAt: nil, failure: nil)
            precondition(view.bounds.height == 250, "Keep real limits on every plan")
            view.update(quota: Quota(primary: nil, secondary: nil), account: account, updatedAt: nil, failure: nil)
            precondition(view.bounds.height == 124)
        }
        precondition(QuotaWindow(usedPercent: 1, windowDurationMins: 15, resetsAt: nil).label == "15분")
        print("PASS: missing windows, real limits on all plans, dynamic height")
    }
}
