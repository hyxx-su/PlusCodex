import AppKit

enum CLIInstallation {
    static func executable(_ provider: AIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let directories = searchDirectories(home: home, environment: environment)
        if provider == .codex {
            return codexExecutable(appBundles: codexAppBundles(home: home), directories: directories)
        }
        let name = provider == .claude ? "claude" : provider.rawValue
        return findExecutable(name: name, directories: directories)
    }

    /// The desktop app's internal CLI location has changed across releases.
    /// Prefer its registered bundle, then fall back to a separately installed CLI.
    static func codexExecutable(appBundles: [URL], directories: [String]) -> String? {
        let relativePaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex"
        ]
        for bundle in appBundles {
            for relativePath in relativePaths {
                let candidate = bundle.appendingPathComponent(relativePath).path
                if isExecutable(candidate) { return candidate }
            }
        }
        return findExecutable(name: "codex", directories: directories)
    }

    private static func codexAppBundles(home: URL) -> [URL] {
        var bundles: [URL] = []
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            bundles.append(registered)
        }
        for directory in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            bundles.append(directory.appendingPathComponent("ChatGPT.app"))
            bundles.append(directory.appendingPathComponent("Codex.app"))
        }
        var seen = Set<String>()
        return bundles.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func searchDirectories(home: URL, environment: [String: String]) -> [String] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [home.appendingPathComponent(".local/bin").path,
                        home.appendingPathComponent(".npm-global/bin").path,
                        home.appendingPathComponent(".bun/bin").path,
                        home.appendingPathComponent(".volta/bin").path,
                        home.appendingPathComponent(".asdf/shims").path,
                        home.appendingPathComponent(".local/share/mise/shims").path,
                        home.appendingPathComponent(".local/share/pnpm").path,
                        home.appendingPathComponent("Library/pnpm").path,
                        home.appendingPathComponent(".yarn/bin").path,
                        home.appendingPathComponent(".nix-profile/bin").path,
                        home.appendingPathComponent(".cargo/bin").path,
                        home.appendingPathComponent("bin").path,
                        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        // Finder-launched apps do not inherit the interactive shell's Node manager PATH.
        for root in [".nvm/versions/node", ".local/share/fnm/node-versions"] {
            let base = home.appendingPathComponent(root)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for entry in entries.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                directories.append(base.appendingPathComponent(entry)
                    .appendingPathComponent(root.contains("fnm") ? "installation/bin" : "bin").path)
            }
        }
        return directories
    }

    static func findExecutable(name: String, directories: [String]) -> String? {
        directories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first(where: isExecutable)
    }

    private static func isExecutable(_ candidate: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: candidate, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: candidate)
    }
}
