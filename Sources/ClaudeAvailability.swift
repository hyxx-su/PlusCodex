import AppKit

/// A provider toggle requires evidence that PlusCodex can display subscription usage.
/// Missing Desktop usage is not proof of a Free plan, but must not appear enabled.
enum ClaudeAvailability {
    enum State: Equatable {
        case notInstalled
        case confirmedFree
        case usageUnavailable
        case availableOrUnknown

        var guidance: String? {
            switch self {
            case .notInstalled: return "미설치"
            case .confirmedFree, .usageUnavailable: return "클로드 코드 구독을 활성화하세요."
            case .availableOrUnknown: return nil
            }
        }

        var actionURL: URL? {
            switch self {
            case .notInstalled: return URL(string: "https://code.claude.com/docs/en/setup")
            case .confirmedFree, .usageUnavailable: return URL(string: "https://claude.ai/upgrade")
            case .availableOrUnknown: return nil
            }
        }
    }

    static func classify(desktopInstalled: Bool, cliInstalled: Bool, subscriptionType: String?,
                         desktopHasUsage: Bool = false) -> State {
        guard desktopInstalled || cliInstalled else { return .notInstalled }
        // Desktop and CLI can use different accounts. Either route with usable
        // subscription usage is enough; an empty Desktop cache is not enough.
        if desktopInstalled && desktopHasUsage { return .availableOrUnknown }
        if cliInstalled, let plan = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            return isConfirmedFree(plan) ? .confirmedFree : .availableOrUnknown
        }
        return .usageUnavailable
    }

    static func isConfirmedFree(_ subscriptionType: String?) -> Bool {
        guard let plan = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return plan == "free" || plan.hasPrefix("free_") || plan.hasSuffix("_free")
    }

    static func current() -> State {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktopCandidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop"),
            URL(fileURLWithPath: "/Applications/Claude.app"),
            home.appendingPathComponent("Applications/Claude.app")
        ].compactMap { $0 }
        let desktopInstalled = desktopCandidates.contains {
            guard let bundle = Bundle(url: $0),
                  bundle.bundleIdentifier == "com.anthropic.claudefordesktop",
                  let executable = bundle.executableURL else { return false }
            return FileManager.default.isExecutableFile(atPath: executable.path)
        }
        let cliInstalled = CLIInstallation.executable(.claude) != nil
        guard desktopInstalled || cliInstalled else { return .notInstalled }
        let environment = ProcessInfo.processInfo.environment
        if cliInstalled && (environment["ANTHROPIC_API_KEY"]?.isEmpty == false
            || ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
                .contains(where: { environment[$0] == "1" })) {
            return .availableOrUnknown
        }
        return classify(desktopInstalled: desktopInstalled, cliInstalled: cliInstalled,
                        subscriptionType: cliInstalled ? ExternalUsageClient.claudeSubscriptionType() : nil,
                        desktopHasUsage: desktopInstalled && ClaudeDesktopUsage.fetch()?.quota.windows.isEmpty == false)
    }
}
