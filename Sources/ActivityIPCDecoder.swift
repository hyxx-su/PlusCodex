import Foundation

/// Project the IPC document before creating Foundation dictionaries. Decoding
/// full conversation bodies produces a large temporary object graph even though
/// the monitor only retains status metadata. Unknown fields remain unmaterialized.
enum ActivityIPCDecoder {
    static func decode(_ data: Data) throws -> [String: Any] {
        try JSONDecoder().decode(Message.self, from: data).value
    }

    private indirect enum Shape {
        case object([String: Shape]), dictionary(Shape), array(Shape), scalar, presence, patch
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
    private static let turn: Shape = .object([
        "turnId": .scalar, "status": .scalar, "turnStartedAtMs": .scalar
    ])
    private static let history: Shape = .object([
        "history": .object(["entitiesByKey": .dictionary(turn)])
    ])
    private static let questions: Shape = .array(.object([
        "options": .array(.object(["label": .scalar]))
    ]))
    private static let request: Shape = {
        var fields: [String: Shape] = ["id": .scalar, "method": .scalar, "completed": .scalar,
                                       "questions": questions]
        let metadata = ["appContext", "connectorId", "pluginId", "mcpToolCall", "appName"]
        for key in metadata { fields[key] = .presence }
        var params: [String: Shape] = ["questions": questions]
        for key in metadata { params[key] = .presence }
        fields["params"] = .object(params)
        return .object(fields)
    }()
    private static let runtime: Shape = .object(["type": .scalar, "activeFlags": .array(.scalar)])
    private static let state: Shape = .object([
        "title": .scalar, "updatedAt": .scalar, "hasUnreadTurn": .scalar,
        "threadRuntimeStatus": runtime, "requests": .array(request), "turnHistory": history
    ])
    private struct Message: Decodable {
        let value: [String: Any]
        init(from decoder: Decoder) throws {
            value = try read(decoder, .object([
                "type": .scalar, "method": .scalar, "version": .scalar,
                "requestId": .scalar, "sourceClientId": .scalar,
                "result": .object(["clientId": .scalar]),
                "params": .object([
                    "hostId": .scalar, "conversationId": .scalar, "clientId": .scalar,
                    "status": .scalar, "hasUnreadTurn": .scalar,
                    "change": .object([
                        "type": .scalar, "revision": .scalar, "baseRevision": .scalar,
                        "conversationState": state, "patches": .array(.patch)
                    ])
                ])
            ])) as? [String: Any] ?? [:]
        }
    }

    private static func read(_ decoder: Decoder, _ shape: Shape) throws -> Any {
        switch shape {
        case .presence:
            return NSNull()
        case .scalar:
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { return NSNull() }
            // Match JSONSerialization's numeric bridging for the existing consumer
            // (for example an integral timestamp is also read as Double).
            if let result = try? value.decode(Bool.self) { return NSNumber(value: result) }
            if let result = try? value.decode(Int.self) { return NSNumber(value: result) }
            if let result = try? value.decode(Double.self) { return NSNumber(value: result) }
            if let result = try? value.decode(String.self) { return result }
            return NSNull()
        case .array(let element):
            guard var container = try? decoder.unkeyedContainer() else { return NSNull() }
            var result: [Any] = []
            while !container.isAtEnd { result.append(try read(container.superDecoder(), element)) }
            return result
        case .object(let fields):
            guard let container = try? decoder.container(keyedBy: Key.self) else { return NSNull() }
            var result: [String: Any] = [:]
            for (name, field) in fields where container.contains(Key(name)) {
                result[name] = try read(container.superDecoder(forKey: Key(name)), field)
            }
            return result
        case .dictionary(let element):
            guard let container = try? decoder.container(keyedBy: Key.self) else { return NSNull() }
            var result: [String: Any] = [:]
            for key in container.allKeys { result[key.stringValue] = try read(container.superDecoder(forKey: key), element) }
            return result
        case .patch:
            guard let container = try? decoder.container(keyedBy: Key.self) else { return NSNull() }
            var result: [String: Any] = [:]
            for name in ["op", "type", "path"] where container.contains(Key(name)) {
                result[name] = try read(container.superDecoder(forKey: Key(name)), name == "path" ? .array(.scalar) : .scalar)
            }
            guard let path = result["path"] as? [Any], let root = path.first as? String,
                  container.contains(Key("value")) else { return result }
            let valueShape: Shape?
            switch root {
            case "title", "updatedAt", "hasUnreadTurn": valueShape = .scalar
            case "activeFlags": valueShape = path.count == 1 ? .array(.scalar) : .scalar
            case "threadRuntimeStatus":
                valueShape = path.count == 1 ? runtime
                    : (path.count == 2 && path[1] as? String == "activeFlags" ? .array(.scalar) : .scalar)
            case "requests": valueShape = path.count == 1 ? .array(request) : nil
            case "turnHistory":
                if path.count == 1 { valueShape = history }
                else if path.count == 3 { valueShape = .dictionary(turn) }
                else if path.count == 4 { valueShape = turn }
                else if path.count == 5, path[4] as? String == "status" { valueShape = .scalar }
                else { valueShape = nil }
            default: valueShape = nil
            }
            if let valueShape { result["value"] = try read(container.superDecoder(forKey: Key("value")), valueShape) }
            return result
        }
    }
}
