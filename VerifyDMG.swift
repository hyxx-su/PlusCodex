import Foundation
import CoreFoundation

// Resolve Finder's legacy background alias after remounting the final image.
let alias = Data(base64Encoded: CommandLine.arguments[1])!
guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(nil, alias as CFData)?.takeRetainedValue() else {
    fatalError("Invalid Finder background alias")
}
var stale = false
let url = try URL(resolvingBookmarkData: bookmark as Data, options: [.withoutUI, .withoutMounting],
                  relativeTo: nil, bookmarkDataIsStale: &stale)
precondition(FileManager.default.fileExists(atPath: url.path))
FileHandle.standardError.write(Data("Resolved: \(url.path)\n".utf8))
precondition(url.standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL)
print("PASS: Finder background alias resolves to the remounted image")
