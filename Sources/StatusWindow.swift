import AppKit

final class StatusWindow: NSWindowController {
    private let status = NSTextField(wrappingLabelWithString: L10n.text("사용량 조회 준비 중…"))
    private let retry = NSButton(title: L10n.text("지금 새로고침"), target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "")
    private let help = NSTextField(wrappingLabelWithString: "")
    var onRefresh: (() -> Void)?
    var statusText: String { status.stringValue }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.text("PlusCodex 실행 상태")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        heading.stringValue = L10n.text("PlusCodex가 실행 중입니다")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.frame = NSRect(x: 24, y: 222, width: 412, height: 30)
        status.font = .systemFont(ofSize: 13)
        status.isSelectable = true
        status.frame = NSRect(x: 24, y: 114, width: 412, height: 96)
        help.stringValue = L10n.text("메뉴바 아이콘이 보이지 않으면 다른 앱의 메뉴나 노치에 가려졌는지 확인하세요. 이 창을 닫아도 PlusCodex는 계속 실행됩니다.")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 12)
        help.frame = NSRect(x: 24, y: 54, width: 412, height: 52)
        retry.frame = NSRect(x: 22, y: 16, width: 130, height: 30)
        retry.bezelStyle = .rounded
        retry.target = self
        retry.action = #selector(refresh)
        for view in [heading, status, help, retry] { window.contentView?.addSubview(view) }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(quota: Quota?, fetching: Bool, failure: String?) {
        retry.isEnabled = !fetching
        if let failure {
            status.stringValue = L10n.text("사용량 조회 실패\n%@\n앱은 실행 중입니다. Codex 설치 및 로그인 상태를 확인해 주세요.", failure)
        } else if let quota {
            let limits = [quota.primary, quota.secondary].compactMap { $0 }
                .map { L10n.text("%@ %d%% 남음", $0.label, $0.remaining) }.joined(separator: " · ")
            status.stringValue = L10n.text("사용량 연결 정상\n%@", limits) + (fetching ? L10n.text("\n추가 정보를 조회 중입니다…") : "")
        } else {
            status.stringValue = fetching ? L10n.text("사용량 조회 중…\n네트워크와 Codex 응답을 기다리고 있습니다.") : L10n.text("사용량 조회 준비 중…")
        }
    }

    func reloadLocalization() {
        window?.title = L10n.text("PlusCodex 실행 상태")
        heading.stringValue = L10n.text("PlusCodex가 실행 중입니다")
        help.stringValue = L10n.text("메뉴바 아이콘이 보이지 않으면 다른 앱의 메뉴나 노치에 가려졌는지 확인하세요. 이 창을 닫아도 PlusCodex는 계속 실행됩니다.")
        retry.title = L10n.text("지금 새로고침")
    }

    @objc private func refresh() { onRefresh?() }
}
