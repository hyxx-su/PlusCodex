import AppKit
import UserNotifications

enum NotificationIconProvider {
    private static let blackCodexPNG: Data? = {
        let url = Bundle.main.url(forResource: "Codex", withExtension: "svg")
            ?? URL(fileURLWithPath: "Resources/Codex.svg")
        guard let source = NSImage(contentsOf: url),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: 256, height: 256)
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        source.draw(in: rect)
        NSColor.black.setFill()
        rect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }()

    private static let notificationPNGs: [AIProvider: Data] = {
        var result: [AIProvider: Data] = [:]
        for provider in AIProvider.allCases {
            let source: NSImage?
            if provider == .codex {
                source = blackCodexPNG.flatMap { NSImage(data: $0) }
            } else {
                let name = "Notification" + provider.resource
                let url = Bundle.main.url(forResource: name, withExtension: "png")
                    ?? URL(fileURLWithPath: "Resources/\(name).png")
                source = NSImage(contentsOf: url)
            }
            guard let source,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let rect = NSRect(x: 0, y: 0, width: 256, height: 256)
            NSColor.white.setFill()
            rect.fill(using: .copy)
            source.draw(in: rect.insetBy(dx: 12, dy: 12), from: .zero,
                        operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            if let data = bitmap.representation(using: .png, properties: [:]) { result[provider] = data }
        }
        return result
    }()

    private static let iconURLs: [AIProvider: URL] = Dictionary(uniqueKeysWithValues:
        AIProvider.allCases.map { provider in
            (provider, FileManager.default.temporaryDirectory
                .appendingPathComponent("PlusCodex-notification-white-\(provider.rawValue)-\(UUID().uuidString).png"))
        })

    static func iconURL(for provider: AIProvider) -> URL? {
        guard let data = notificationPNGs[provider], let url = iconURLs[provider] else { return nil }
        // Notification attachments may take ownership of the file; recreate it if moved.
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        }
        return url
    }

    static func apply(to content: UNMutableNotificationContent, provider: AIProvider) {
        guard let url = iconURL(for: provider) else { return }

        if let iconClass = NSClassFromString("UNNotificationIcon") as? NSObject.Type {
            let sel = Selector(("iconAtPath:"))
            if iconClass.responds(to: sel) {
                let icon = iconClass.perform(sel, with: url.path)?.takeUnretainedValue()
                content.setValue(icon, forKey: "icon")
                content.setValue(true, forKey: "shouldShowSubordinateIcon")
            }
        }

        if let attachment = try? UNNotificationAttachment(identifier: "provider-icon", url: url, options: nil) {
            content.attachments = [attachment]
        }
    }
}
