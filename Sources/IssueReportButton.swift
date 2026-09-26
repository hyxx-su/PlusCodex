import AppKit

/// A small support link shared by provider error screens.
final class IssueReportButton: NSButton {
    static let issueURL = URL(string: "https://github.com/hyxx-su/PlusCodex/issues/new")!
    var openURL: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        alignment = .center
        target = self
        action = #selector(reportIssue)

        let prompt = L10n.text("무슨 일이 있나요? ")
        let link = L10n.text("제보해주세요")
        let title = NSMutableAttributedString(string: prompt + link, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        title.addAttributes([
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ], range: NSRange(location: (prompt as NSString).length, length: (link as NSString).length))
        attributedTitle = title
        toolTip = L10n.text("GitHub 이슈 작성 페이지 열기")
        setAccessibilityLabel(prompt + link)
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func reportIssue() {
        enclosingMenuItem?.menu?.cancelTracking()
        openURL(Self.issueURL)
    }
}
