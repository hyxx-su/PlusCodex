import Foundation

/// Grok usage is read from the CLI login's billing endpoint, not the web app.
enum GrokAvailability {
    enum State: Equatable {
        case notInstalled
        case notAuthenticated
        case readyToCheck

        var guidance: String? {
            switch self {
            case .notInstalled: return "미설치"
            case .notAuthenticated: return "Grok에 로그인하세요."
            case .readyToCheck: return nil
            }
        }

        var actionURL: URL? {
            switch self {
            case .notInstalled: return URL(string: "https://x.ai/build")
            case .notAuthenticated: return URL(string: "https://docs.x.ai/build/cli/reference")
            case .readyToCheck: return nil
            }
        }
    }

    static func classify(cliInstalled: Bool, authenticated: Bool) -> State {
        guard cliInstalled else { return .notInstalled }
        return authenticated ? .readyToCheck : .notAuthenticated
    }

    static func current() -> State {
        guard CLIInstallation.executable(.grok) != nil else { return .notInstalled }
        let home = ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .notAuthenticated
        }
        return classify(cliInstalled: true, authenticated: ExternalUsageClient.grokSession(root) != nil)
    }

    static func hasDisplayableUsage(_ snapshot: QuotaSnapshot) -> Bool {
        guard !snapshot.quota.windows.isEmpty else { return false }
        let tier = snapshot.account?.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return !tier.contains("free") && !["basic", "x_basic", "x basic", "x-basic"].contains(tier)
    }
}
