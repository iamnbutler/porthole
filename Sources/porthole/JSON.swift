import Foundation

enum JSON {
    static func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .sortedKeys])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ s: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
    }

    static func decodeObject(_ s: String) throws -> [String: Any] {
        guard let obj = try decode(s) as? [String: Any] else { throw NetError("expected a JSON object") }
        return obj
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? {
        if let i = self[k] as? Int { return i }
        if let d = self[k] as? Double { return Int(d) }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let d = self[k] as? Double { return d }
        if let i = self[k] as? Int { return Double(i) }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func obj(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
}
