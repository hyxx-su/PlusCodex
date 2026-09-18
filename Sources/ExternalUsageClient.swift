import Foundation
import Security
import CryptoKit

enum UsageFailure: LocalizedError {
    case message(String)
    case throttled(Date)
    case authentication
    case missingScope
    case credentialsUnavailable
    case server
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .throttled: return L10n.text("조회 요청이 많습니다. 잠시 후 다시 확인합니다.")
        case .authentication: return L10n.text("사용량 API가 인증을 거부했습니다. 해당 AI CLI의 로그인 상태를 확인하세요.")
        case .missingScope: return L10n.text("사용량 조회 권한(user:profile)이 없습니다. Claude CLI에서 다시 로그인하세요.")
        case .credentialsUnavailable: return L10n.text("Claude 인증 정보를 읽지 못했습니다. CLI 로그인과 키체인 접근을 확인하세요.")
        case .server: return L10n.text("사용량 서버에 일시적인 오류가 발생했습니다.")
        }
    }
}

/// Read-only adapters informed by Orca's rate-limit fetchers (MIT, see Resources/Orca-LICENSE).
/// Credentials remain in memory and are sent only to the provider's fixed HTTPS endpoint.
enum ExternalUsageClient {
    static func fetch(_ provider: AIProvider) throws -> QuotaSnapshot {
        switch provider {
        case .claude: return try claude()
        case .grok: return try grok()
        case .codex: return try QuotaClient.fetchSnapshot()
        }
    }

    static func number(_ value: Any?) -> Double? {
        guard !(value is NSNull), let value else { return nil }
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        if let text = value as? String, let n = Double(text), n.isFinite { return n }
        return nil
    }

    static func timestamp(_ value: Any?) -> Double? {
        if let n = number(value), n > 0 { return n > 10_000_000_000 ? n / 1000 : n }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)?.timeIntervalSince1970
    }

    static func quota(_ windows: [QuotaWindow]) -> Quota {
        Quota(primary: windows.first, secondary: windows.dropFirst().first,
              additional: Array(windows.dropFirst(2)))
    }

    static func parseClaude(_ data: [String: Any]) throws -> Quota {
        var windows: [QuotaWindow] = []
        let definitions = [("five_hour", "5시간", 300), ("seven_day", "주간", 10080),
                           ("seven_day_sonnet", "Sonnet 주간", 10080), ("seven_day_opus", "Opus 주간", 10080),
                           ("fable_weekly", "Fable 주간", 10080), ("seven_day_fable", "Fable 주간", 10080)]
        for (key, title, minutes) in definitions {
            guard let raw = data[key] as? [String: Any],
                  let percent = number(raw["utilization"] ?? raw["used_percentage"]),
                  !windows.contains(where: { $0.label == title }) else { continue }
            windows.append(QuotaWindow(usedPercent: percent, windowDurationMins: minutes,
                                       resetsAt: timestamp(raw["resets_at"]), customLabel: title))
        }
        for raw in data["limits"] as? [[String: Any]] ?? [] {
            guard let percent = number(raw["percent"]), let kind = raw["kind"] as? String else { continue }
            let model = ((raw["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let title: String
            let minutes: Int
            switch kind {
            case "session": title = "5시간"; minutes = 300
            case "weekly_all": title = "주간"; minutes = 10080
            case "weekly_scoped": title = "\(model ?? "모델") 주간"; minutes = 10080
            default: continue
            }
            if !windows.contains(where: { $0.label == title }) {
                windows.append(QuotaWindow(usedPercent: percent, windowDurationMins: minutes,
                    resetsAt: timestamp(raw["resets_at"]), customLabel: title))
            }
        }
        guard !windows.isEmpty else { throw UsageFailure.message(L10n.text("이 계정에서 구독 사용량을 제공하지 않습니다.")) }
        return quota(windows)
    }

    static func parseGrok(_ data: [String: Any]) -> Quota? {
        let config = data["config"] as? [String: Any] ?? data
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let reset = timestamp(period["end"] ?? config["billingPeriodEnd"])
        if let percent = number(config["creditUsagePercent"]) {
            let kind = period["type"] as? String
            let monthly = kind == "USAGE_PERIOD_TYPE_MONTHLY"
            let weekly = kind == "USAGE_PERIOD_TYPE_WEEKLY"
            return quota([QuotaWindow(usedPercent: percent,
                windowDurationMins: monthly ? 43200 : weekly ? 10080 : nil, resetsAt: reset,
                customLabel: monthly ? "1개월" : weekly ? "주간" : "사용 한도")])
        }
        let limit = number((config["monthlyLimit"] as? [String: Any])?["val"])
        let used = number((config["used"] as? [String: Any])?["val"])
        guard let limit, let used, limit > 0, used >= 0 else { return nil }
        return quota([QuotaWindow(usedPercent: min(used / limit, 1) * 100, windowDurationMins: 43200,
                                  resetsAt: reset, customLabel: "1개월")])
    }

    static func recoveringClaude(oauth: () throws -> QuotaSnapshot, cli: () throws -> Quota) throws -> QuotaSnapshot {
        do { return try oauth() }
        catch let error as UsageFailure {
            switch error {
            case .authentication, .credentialsUnavailable, .server: break
            default: throw error
            }
        }
        let result = Result { try cli() }
        // Honor throttling; a second route must not bypass the server's cooldown.
        if case .failure(UsageFailure.throttled(let date)) = result { throw UsageFailure.throttled(date) }
        // Claude itself may rotate credentials during startup. Never write tokens ourselves.
        if let refreshed = try? oauth() { return refreshed }
        return QuotaSnapshot(quota: try result.get(), account: nil)
    }

    private static func claude() throws -> QuotaSnapshot {
        try recoveringClaude(oauth: claudeOAuth, cli: ClaudeCLIUsage.fetch)
    }

    private static func claudeOAuth() throws -> QuotaSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        var services = ["Claude Code-credentials"]
        if ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil {
            let suffix = SHA256.hash(data: Data(config.path.precomposedStringWithCanonicalMapping.utf8))
                .map { String(format: "%02x", $0) }.joined().prefix(8)
            services.insert("Claude Code-credentials-\(suffix)", at: 0)
        }
        var oauth: [String: Any]?
        for service in services {
            if let data = BackgroundKeychain.read(service: service),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = root["claudeAiOauth"] as? [String: Any], value["accessToken"] is String {
                oauth = value; break
            }
        }
        if oauth == nil, let data = try? Data(contentsOf: config.appendingPathComponent(".credentials.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            oauth = root["claudeAiOauth"] as? [String: Any]
        }
        guard let token = oauth?["accessToken"] as? String, !token.isEmpty else {
            throw UsageFailure.credentialsUnavailable
        }
        let data = try request("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0"])
        let metadataURL = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil
            ? home.appendingPathComponent(".claude.json") : config.appendingPathComponent(".claude.json")
        let metadata = (try? Data(contentsOf: metadataURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let email = (metadata?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
        return QuotaSnapshot(quota: try parseClaude(data),
            account: CodexAccount(email: email, planType: oauth?["subscriptionType"] as? String))
    }

    static func grokSession(_ root: [String: Any]) -> [String: Any]? {
        let candidates = root.sorted { $0.key < $1.key }.filter { $0.key == "https://auth.x.ai" || $0.key.hasPrefix("https://auth.x.ai::") }
        return candidates.compactMap { $0.value as? [String: Any] }.first {
            guard let token = $0["key"] as? String, !token.isEmpty else { return false }
            return timestamp($0["expires_at"]).map { $0 > Date().timeIntervalSince1970 } ?? true
        }
    }

    private static func grok() throws -> QuotaSnapshot {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        guard let bytes = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw UsageFailure.message(L10n.text("Grok CLI를 설치하고 grok login으로 로그인하세요."))
        }
        guard let session = grokSession(root), let token = session["key"] as? String else {
            throw UsageFailure.message(L10n.text("Grok을 실행해 로그인 상태를 갱신하세요. 메시지는 보낼 필요 없습니다."))
        }
        var headers = ["Authorization": "Bearer \(token)", "X-XAI-Token-Auth": "xai-grok-cli"]
        headers["x-userid"] = session["user_id"] as? String
        var data = try request("https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: headers)
        if parseGrok(data) == nil { data = try request("https://cli-chat-proxy.grok.com/v1/billing", headers: headers) }
        guard let quota = parseGrok(data) else {
            throw UsageFailure.message(L10n.text("이 계정에서 사용량 퍼센트를 제공하지 않습니다."))
        }
        let config = data["config"] as? [String: Any] ?? data
        return QuotaSnapshot(quota: quota, account: CodexAccount(email: session["email"] as? String,
            planType: config["subscriptionTier"] as? String))
    }

    private static func request(_ address: String, headers: [String: String]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 12)
        request.allHTTPHeaderFields = headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(UsageFailure.message(L10n.text("조회 시간이 초과되었습니다.")))
        let session = URLSession(configuration: .ephemeral, delegate: NoUsageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            result = Result {
                if error != nil { throw UsageFailure.message(L10n.text("네트워크 연결을 확인한 후 다시 시도하세요.")) }
                guard let response = response as? HTTPURLResponse else { throw UsageFailure.message(L10n.text("응답을 확인할 수 없습니다.")) }
                if response.statusCode == 429 {
                    let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900
                    throw UsageFailure.throttled(Date().addingTimeInterval(max(60, seconds)))
                }
                if response.statusCode == 403,
                   String(data: data ?? Data(), encoding: .utf8)?.contains("user:profile") == true {
                    throw UsageFailure.missingScope
                }
                if [401, 403].contains(response.statusCode) { throw UsageFailure.authentication }
                if response.statusCode >= 500 { throw UsageFailure.server }
                if response.statusCode == 412 { throw UsageFailure.message(L10n.text("이 팀 계정은 사용량 조회를 지원하지 않습니다.")) }
                guard response.statusCode == 200, let data,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw UsageFailure.message(L10n.text("사용량 조회에 실패했습니다 (HTTP %d).", response.statusCode))
                }
                return object
            }
        }
        task.resume()
        // URLSession guarantees completion after timeout/cancellation; avoid racing result reads.
        semaphore.wait()
        return try result.get()
    }
}

private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
