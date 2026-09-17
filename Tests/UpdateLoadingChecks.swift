import AppKit

@main struct UpdateLoadingChecks {
    static func main() {
        _ = NSApplication.shared
        let panel = QuotaMenuView(quota: nil, updatedAt: nil, failure: nil,
                                  intro: true, checkingForUpdates: true)
        let loader = panel.subviews.compactMap { $0 as? QuotaLoadingView }.first!
        precondition(!loader.captionHidden)
        let labels = loader.subviews.compactMap { $0 as? NSTextField }
        precondition(labels.map(\.stringValue) == ["업데이트 확인 중", "최신 버전인지 확인하고 있어요."])
        precondition(labels.allSatisfy { loader.bounds.contains($0.frame) })
        precondition(loader.logoPoint.y < labels[0].frame.minY)
        let normal = QuotaMenuView(quota: nil, updatedAt: nil, failure: nil)
        precondition(normal.subviews.isEmpty, "Normal refresh must not show update loader")
        if CommandLine.arguments.count > 1 {
            let window = NSWindow(contentRect: panel.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = panel
            panel.layoutSubtreeIfNeeded()
            let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds)!
            panel.cacheDisplay(in: panel.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS: update checking captions, bounds, logo spacing, normal dashboard")
    }
}
