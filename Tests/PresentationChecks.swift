import AppKit
import Sparkle

/// Sparkle's public secure-coding initializer supplies an offline UI fixture.
/// No updater session, download or installer is created by this test.
private final class UpdateStateFixture: NSCoder {
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { 0 }
    override func decodeBool(forKey key: String) -> Bool { key == "SPUUserUpdateStateUserInitiated" }
}

@main struct PresentationChecks {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "PlusCodex.presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsWindow(settings: ProviderSettings(defaults: defaults))
        for provider in AIProvider.allCases { settings.update(provider, status: "연결됨 · 사용량 조회 완료") }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: name)
            settings.window!.appearance = NSAppearance(named: name)
            let view = settings.window!.contentView!
            try snapshot(view, appearance: name, path: "/tmp/pluscodex-settings-\(name.rawValue).png")
            // Simulate a status button whose appearance differs from the system.
            let button = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
            button.appearance = NSAppearance(named: name == .aqua ? .darkAqua : .aqua)
            view.addSubview(button)
            settings.window!.orderFront(nil)
            let menu = NSMenu()
            let item = NSMenuItem()
            let panel = QuotaMenuView(quota: nil, updatedAt: nil, failure: nil)
            item.view = panel; menu.addItem(item)
            var observed: NSAppearance.Name?
            let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                observed = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                menu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            menu.popUpFollowingSystemAppearance(from: button)
            precondition(observed == name, "Popup must follow system: expected \(name), actual \(String(describing: observed))")
            precondition(button.subviews.isEmpty, "Temporary popup anchor must be removed")
            button.removeFromSuperview()
        }
        settings.window!.orderOut(nil)
        NSApp.appearance = NSAppearance(named: .aqua)

        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let update = SUAppcastItem(dictionary: [
            "description": "<h3>화면 및 업데이트 개선</h3><ul><li>시스템 라이트·다크 모드를 따릅니다.</li><li>설정 스위치와 간격을 정리했습니다.</li><li>설치 전에 업데이트 내용을 확인할 수 있습니다.</li></ul>",
            "enclosure": ["url": "https://example.invalid/PlusCodex-test.zip",
                          "sparkle:version": "999", "sparkle:shortVersionString": "테스트 버전"]
        ])!
        var choice: SPUUserUpdateChoice?
        driver.showUpdateFound(with: update, state: SPUUserUpdateState(coder: UpdateStateFixture())!) { choice = $0 }
        driver.showUpdateInFocus()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let window = NSApp.windows.first { $0.isVisible && $0.title == "소프트웨어 업데이트" }!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
        precondition(buttons.contains { $0.title == "업데이트 설치" })
        precondition(buttons.contains { $0.title == "이 버전 건너뛰기" })
        precondition(choice == nil, "Installation requires a user choice")
        try snapshot(window.contentView!, appearance: .aqua, path: "/tmp/pluscodex-update-preview.png")
        let later = buttons.first { $0.title == "나중에" }!
        later.performClick(nil)
        precondition(choice == .dismiss)
        driver.dismissUpdateInstallation()
        print("PASS: compact settings in both appearances; Korean native update window, install/skip/later controls and explicit choice")
    }

    private static func snapshot(_ view: NSView, appearance: NSAppearance.Name, path: String) throws {
        view.window?.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(calibratedWhite: appearance == .aqua ? 0.96 : 0.15, alpha: 1).setFill()
        view.bounds.fill()
        let content = NSImage(size: view.bounds.size)
        content.addRepresentation(bitmap)
        content.draw(in: view.bounds)
        image.unlockFocus()
        let opaque = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try opaque.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
