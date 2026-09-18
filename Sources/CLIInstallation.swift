import Foundation

enum CLIInstallation {
    static func executable(_ provider: AIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let name = provider == .claude ? "claude" : provider.rawValue
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [home.appendingPathComponent(".local/bin").path,
                        home.appendingPathComponent(".npm-global/bin").path,
                        home.appendingPathComponent(".bun/bin").path,
                        home.appendingPathComponent(".volta/bin").path,
                        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        // Finder-launched apps do not inherit the interactive shell's Node manager PATH.
        for root in [".nvm/versions/node", ".local/share/fnm/node-versions"] {
            let base = home.appendingPathComponent(root)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for entry in entries.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                directories.append(base.appendingPathComponent(entry)
                    .appendingPathComponent(root.contains("fnm") ? "installation/bin" : "bin").path)
            }
        }
        return findExecutable(name: name, directories: directories)
    }

    static func findExecutable(name: String, directories: [String]) -> String? {
        directories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { path in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                    && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
            }
    }
}
