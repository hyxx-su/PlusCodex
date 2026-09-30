import Foundation
import Darwin

@main
struct ActivityIPCChecks {
    static func main() throws {
        let state: [String: Any] = [
            "title": "한글 \"제목\" 😀", "updatedAt": 123, "hasUnreadTurn": true,
            "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]],
            "turnHistory": ["history": ["entitiesByKey": ["t": [
                "turnId": "turn-1", "status": "completed", "turnStartedAtMs": 123,
                "items": [["text": "must not survive projection"]]
            ]]]],
            "requests": [["id": 42, "method": "tool/requestUserInput", "completed": false,
                           "params": ["appContext": ["large": "ignored"],
                                      "questions": [["options": [["label": "Allow"], ["label": "Deny"]]]]]]],
            "messages": [["text": "ignored"]]
        ]
        let original: [String: Any] = ["type": "broadcast", "method": "thread-stream-state-changed",
            "version": 11, "sourceClientId": "owner", "params": ["hostId": "local", "conversationId": "thread",
            "change": ["type": "snapshot", "revision": 5, "conversationState": state]]]
        let parsed = try ActivityIPCDecoder.decode(JSONSerialization.data(withJSONObject: original))
        let params = parsed["params"] as! [String: Any]
        let change = params["change"] as! [String: Any]
        let projected = change["conversationState"] as! [String: Any]
        precondition(projected["title"] as? String == state["title"] as? String)
        precondition(projected["updatedAt"] as? Double == 123)
        precondition(projected["hasUnreadTurn"] as? Bool == true)
        precondition(projected["messages"] == nil)
        let history = (projected["turnHistory"] as! [String: Any])["history"] as! [String: Any]
        let turn = (history["entitiesByKey"] as! [String: Any])["t"] as! [String: Any]
        precondition(turn["turnId"] as? String == "turn-1" && turn["items"] == nil)
        let request = (projected["requests"] as! [[String: Any]])[0]
        precondition(request["id"] as? Int == 42 && request["completed"] as? Bool == false)
        let requestParams = request["params"] as! [String: Any]
        precondition(requestParams["appContext"] is NSNull)
        precondition((requestParams["questions"] as? [[String: Any]])?.count == 1)

        let paths: [[Any]] = [["title"], ["hasUnreadTurn"], ["threadRuntimeStatus", "activeFlags"],
                             ["turnHistory", "history", "entitiesByKey", "t", "status"],
                             ["requests", 0, "completed"], ["messages", 0, "text"]]
        let values: [Any] = ["new", false, ["waitingOnApproval"], "completed", true, "large ignored text"]
        let patches = zip(paths, values).map { ["path": $0.0, "value": $0.1, "op": "replace"] as [String: Any] }
        let patchMessage: [String: Any] = ["params": ["change": ["type": "patches", "baseRevision": 5,
                                                                "revision": 6, "patches": patches]]]
        let decoded = try ActivityIPCDecoder.decode(JSONSerialization.data(withJSONObject: patchMessage))
        let patchChange = (decoded["params"] as! [String: Any])["change"] as! [String: Any]
        let results = patchChange["patches"] as! [[String: Any]]
        precondition(results[0]["value"] as? String == "new")
        precondition(results[1]["value"] as? Bool == false)
        precondition(results[2]["value"] as? [String] == ["waitingOnApproval"])
        precondition(results[3]["value"] as? String == "completed")
        precondition(results[4]["value"] == nil && results[4]["path"] != nil)
        precondition(results[5]["value"] == nil)
        let initialized = try ActivityIPCDecoder.decode(Data("{\"type\":\"response\",\"method\":\"initialize\",\"result\":{\"clientId\":\"client\"}}".utf8))
        precondition((initialized["result"] as? [String: Any])?["clientId"] as? String == "client")
        do {
            _ = try ActivityIPCDecoder.decode(Data("{invalid".utf8))
            preconditionFailure("Malformed IPC must be rejected")
        } catch {}
        print("PASS: projected snapshot, numeric bridging, approval metadata, patches and malformed IPC")
        if CommandLine.arguments.contains("--stress") { try stress() }
    }

    private static func footprint(peak: Bool = false) -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return peak ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint
    }

    private static func stress() throws {
        let item = "{\"text\":\"" + String(repeating: "tool output ", count: 64) + "\",\"type\":\"text\",\"index\":1}"
        let data = autoreleasepool {
            Data(("{\"params\":{\"change\":{\"conversationState\":{\"title\":\"test\",\"messages\":[" +
                  Array(repeating: item, count: 32768).joined(separator: ",") + "]}}}}").utf8)
        }
        let legacy = CommandLine.arguments.contains("--legacy")
        print("mode=\(legacy ? "full" : "projected") bytes=\(data.count) baseline=\(footprint())")
        for index in 1...12 {
            try autoreleasepool {
                let value = legacy ? try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    : try ActivityIPCDecoder.decode(data)
                // Exercise the same dictionary bridges as ThreadActivityMonitor,
                // not just the lazily decoded top-level Foundation object.
                let params = value["params"] as! [String: Any]
                let change = params["change"] as! [String: Any]
                let state = change["conversationState"] as! [String: Any]
                precondition(state["title"] as? String == "test")
                print("iteration=\(index) during=\(footprint())")
                withExtendedLifetime(value) {}
            }
            print("iteration=\(index) after=\(footprint()) peak=\(footprint(peak: true))")
        }
    }
}
