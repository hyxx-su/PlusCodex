import AppKit
import ApplicationServices

/// Reads only navigation metadata. Never request AXValue, AXTitle, or web content.
enum AntigravityConversationReader {
    static let bundleIDs = ["com.google.antigravity", "dev.antigravity.app"]
    static var hasPermission: Bool { AXIsProcessTrusted() }

    static var foregroundPID: pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, bundleIDs.contains(bundle) else { return nil }
        return app.processIdentifier
    }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func conversationID(from address: String) -> String? {
        let normalized = address.hasPrefix("127.0.0.1:") || address.hasPrefix("localhost:")
            ? "http://" + address : address
        guard let url = URLComponents(string: normalized),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "[::1]"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        let path = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, path[1] == "c",
              let id = UUID(uuidString: String(path[2])) else { return nil }
        return id.uuidString.lowercased()
    }

    /// Called on the existing polling worker; a slow/unavailable AX server fails closed.
    static func currentConversationID(pid: pid_t) -> String? {
        guard hasPermission else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func webID(_ node: AXUIElement) -> String? {
            guard let value = attribute(node, kAXURLAttribute) else { return nil }
            if let url = value as? URL { return conversationID(from: url.absoluteString) }
            if let string = value as? String { return conversationID(from: string) }
            return nil
        }
        guard let window = element(attribute(app, kAXFocusedWindowAttribute)),
              attribute(window, kAXMinimizedAttribute) as? Bool != true else { return nil }

        // Prefer the focused control's web-area ancestor, not links in a sidebar.
        var focused = element(attribute(app, kAXFocusedUIElementAttribute))
        var focusedID: String?
        for _ in 0..<16 {
            guard let node = focused else { break }
            if CFEqual(node, window) {
                if let focusedID { return focusedID }
                break
            }
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" {
                focusedID = webID(node)
            }
            focused = element(attribute(node, kAXParentAttribute))
        }

        // Some Electron windows focus the window itself. Inspect containers only,
        // stop at web areas, and reject ambiguous windows with multiple web areas.
        var queue: [AXUIElement] = [window]
        var index = 0
        var webAreas = 0
        var result: String?
        let containers: Set<String> = ["AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea"]
        while index < queue.count && index < 24 && ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue[index]
            index += 1
            guard let role = attribute(node, kAXRoleAttribute) as? String else { return nil }
            if role == "AXWebArea" {
                webAreas += 1
                result = webID(node)
                if webAreas > 1 { return nil }
            } else if containers.contains(role) {
                if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                    guard queue.count + children.count <= 24 else { return nil }
                    queue.append(contentsOf: children)
                }
            }
        }
        guard index == queue.count, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return webAreas == 1 ? result : nil
    }
}
