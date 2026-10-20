import Foundation
import Security

/// Checks whether Google Gemini (via Antigravity or Gemini CLI) is installed and signed in.
enum GeminiAvailability {
    enum State: Equatable {
        case notInstalled
        case notAuthenticated
        case readyToCheck

        var guidance: String? {
            switch self {
            case .notInstalled: return "미설치"
            case .notAuthenticated: return "로그인 필요"
            case .readyToCheck: return nil
            }
        }

        var actionURL: URL? {
            switch self {
            case .notInstalled: return URL(string: "https://antigravity.google")
            case .notAuthenticated: return URL(string: "https://github.com/google-gemini/gemini-cli")
            case .readyToCheck: return nil
            }
        }
    }

    static func classify(installed: Bool, authenticated: Bool) -> State {
        guard installed else { return .notInstalled }
        return authenticated ? .readyToCheck : .notAuthenticated
    }

    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> State {
        let cliInstalled = CLIInstallation.executable(.gemini, home: home, environment: environment) != nil
        let appInstalled = CLIInstallation.antigravityAppBundles(home: home).contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let installed = cliInstalled || appInstalled
        guard installed else { return .notInstalled }

        let authenticated = hasGeminiCLICredentials(home: home, environment: environment)
            || hasAntigravityLoginState(home: home)
            || hasAntigravityKeychainItem()
        return classify(installed: true, authenticated: authenticated)
    }

    static func geminiDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["GEMINI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return home.appendingPathComponent(".gemini")
    }

    static func hasGeminiCLICredentials(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let dir = geminiDirectory(home: home, environment: environment)
        if let settingsData = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
           let security = settings["security"] as? [String: Any],
           let auth = security["auth"] as? [String: Any],
           let selectedType = (auth["selectedType"] as? String)?.lowercased(),
           selectedType == "api-key" || selectedType == "vertex-ai" {
            // API key and Vertex AI modes do not expose Cloud Code quota buckets.
        } else if let data = try? Data(contentsOf: dir.appendingPathComponent("oauth_creds.json")),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let access = (root["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let refresh = (root["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !access.isEmpty || !refresh.isEmpty { return true }
        }
        return false
    }

    static func hasAntigravityLoginState(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let appStorage = home.appendingPathComponent("Library/Application Support/Antigravity/app_storage.json")
        if let data = try? Data(contentsOf: appStorage),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let username = (root["jetski.onboarding.lastLoginUsername"] as? String)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty {
            return true
        }
        let stateFile = home.appendingPathComponent(".gemini/antigravity/antigravity_state.pbtxt")
        if let text = try? String(contentsOf: stateFile, encoding: .utf8),
           text.contains("AGENT_ONBOARDING_STATE_COMPLETED") {
            return true
        }
        return false
    }

    static func hasAntigravityKeychainItem() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
