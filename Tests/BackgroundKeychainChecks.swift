import Foundation
import Security

@main struct BackgroundKeychainChecks {
    static func main() {
        for original in [true, false] {
            for result in [errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
                var current = original
                var changes: [Bool] = []
                let outcome = BackgroundKeychain.withoutInteraction(get: { (errSecSuccess, current) }, set: {
                    current = $0; changes.append($0); return errSecSuccess
                }, operation: {
                    precondition(!current, "Never read while interaction is enabled")
                    return (result, nil)
                })
                precondition(outcome.0 == result && current == original)
                precondition(changes == [false, original])
            }
        }
        var reads = 0
        _ = BackgroundKeychain.withoutInteraction(get: { (errSecSuccess, true) }, set: { _ in errSecAuthFailed },
            operation: { reads += 1; return (errSecSuccess, nil) })
        _ = BackgroundKeychain.withoutInteraction(get: { (errSecAuthFailed, true) }, set: { _ in preconditionFailure() },
            operation: { reads += 1; return (errSecSuccess, nil) })
        precondition(reads == 0, "Fail closed when UI suppression cannot be established")
        print("PASS: background keychain forbids UI, restores prior state on success/denial/cancellation, fails closed")
    }
}
