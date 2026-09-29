import Foundation

@main struct CodexWakeBridgeChecks {
    static func main() throws {
        precondition(CodexWakeError.failed("thread x already has an active writer").isActiveWriterConflict)
        precondition(!CodexWakeError.failed("thread not found").isActiveWriterConflict)
        precondition(!CodexWakeError.timedOut.isActiveWriterConflict)
        precondition(!CodexWakeError.invalidResponse.isDefiniteServerRejection)
        precondition(CodexWakeDesktopBridge.isIdle(["threadRuntimeStatus": ["type": "idle"]]))
        precondition(!CodexWakeDesktopBridge.isIdle(["threadRuntimeStatus": ["type": "active"]]))
        precondition(!CodexWakeDesktopBridge.isIdle([:]))
        precondition(!CodexWakeDesktopBridge.isIdle(["threadRuntimeStatus": ["type": "idle"],
                                                    "requests": [["completed": false]]]))
        let params = CodexWakeClient.turnStartParams(threadID: "saved", modelName: "gpt-6-luna",
                                                   effort: "low", message: "changed message")
        let payload = CodexWakeDesktopBridge.turnPayload(threadID: "saved", params: params)
        precondition(payload["conversationId"] as? String == "saved")
        let start = payload["turnStart"] as! [String: Any]
        let request = start["request"] as! [String: Any]
        precondition(request["threadId"] as? String == "saved")
        precondition(request["clientUserMessageId"] as? String != nil)
        precondition((request["input"] as! [[String: String]]).first?["text"] == "changed message")
        precondition(request["approvalPolicy"] as? String == "never")
        precondition((request["sandboxPolicy"] as! [String: String])["type"] == "readOnly")
        let accepted: [String: Any] = ["resultType": "success", "handledByClientId": "owner",
                                      "result": ["result": ["turn": ["id": "turn-1"]]]]
        let id = try CodexWakeDesktopBridge.acceptedTurnID(accepted, owner: "owner")
        precondition(id == "turn-1")
        for bad in [["resultType": "error", "error": "timeout"],
                    ["resultType": "success", "handledByClientId": "other"], [:]] {
            do {
                _ = try CodexWakeDesktopBridge.acceptedTurnID(bad, owner: "owner")
                preconditionFailure("Ambiguous delivery must not be accepted")
            } catch let error as CodexWakeError { precondition(!error.isDefiniteServerRejection) }
        }
        if let thread = ProcessInfo.processInfo.environment["PLUSCODEX_WAKE_DIAGNOSTIC_THREAD"] {
            _ = try CodexWakeDesktopBridge().idleOwner(threadID: thread)
            print("PASS: live desktop owner discovery and idle snapshot; no message sent")
        }
        print("PASS: writer routing, idle guard, same-thread payload, changed text, ambiguous response safety")
    }
}
