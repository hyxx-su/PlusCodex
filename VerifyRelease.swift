import Foundation
import CryptoKit

// Public-key-only verification: release validation never needs Keychain access.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Info.plist")), format: nil) as! [String: Any]
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: info["SUPublicEDKey"] as! String)!)
let feed = try Data(contentsOf: folder.appendingPathComponent("appcast.xml"))
guard let marker = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards) else {
    fatalError("Unsigned update feed")
}
let signedContent = feed.prefix(marker.lowerBound)
let signatureBlock = String(decoding: feed.suffix(from: marker.upperBound), as: UTF8.self)
let fields = Dictionary(uniqueKeysWithValues: signatureBlock.split(separator: "\n").compactMap { line -> (String, String)? in
    let parts = line.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
})
precondition(Int(fields["length"] ?? "") == signedContent.count, "Feed length mismatch")
precondition(key.isValidSignature(Data(base64Encoded: fields["edSignature"]!)!, for: signedContent), "Invalid feed signature")
let document = try XMLDocument(data: feed)
for node in try document.nodes(forXPath: "//enclosure") {
    let enclosure = node as! XMLElement
    let url = URL(string: enclosure.attribute(forName: "url")!.stringValue!)!
    precondition(url.scheme == "https" && url.host == "github.com", "Unexpected update origin")
    let data = try Data(contentsOf: folder.appendingPathComponent(url.lastPathComponent))
    precondition(data.count == Int(enclosure.attribute(forName: "length")!.stringValue!)!, "Archive length mismatch")
    let signature = Data(base64Encoded: enclosure.attribute(forName: "sparkle:edSignature")!.stringValue!)!
    precondition(key.isValidSignature(signature, for: data), "Invalid archive signature")
    var damaged = data
    damaged[0] ^= 1
    precondition(!key.isValidSignature(signature, for: damaged), "Corrupted archive must be rejected")
}
print("PASS: public-key feed and archive signatures, byte lengths, corrupt archive rejection")
