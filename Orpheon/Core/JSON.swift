// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// A lenient JSON tree read with dotted paths, the way Spotify's answers are read everywhere in the
/// app: a missing or null field gives `nil`, never an error. (Port of `JsonPaths.kt`.)
enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

// MARK: - Decoding / encoding

extension JSON: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    /// The JSON text of this value (compact).
    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }

    /// Builds a value from plain Swift values (maps and lists nest). Kotlin's `vars("a" to 1)`.
    static func from(_ v: Any?) -> JSON {
        guard let v = v else { return .null }
        switch v {
        case let j as JSON: return j
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(Int64(i))
        case let i as Int64: return .int(i)
        case let i as Int32: return .int(Int64(i))
        case let d as Double: return .double(d)
        case let f as Float: return .double(Double(f))
        case let a as [Any?]: return .array(a.map { JSON.from($0) })
        case let m as [String: Any?]: return .object(m.mapValues { JSON.from($0) })
        default: return .string(String(describing: v))
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByNilLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral,
                ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
    init(floatLiteral value: Double) { self = .double(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

/// GraphQL variables from plain values: `vars(["uri": uri, "offset": 0, "folderUri": nil])`.
func vars(_ pairs: [String: Any?] = [:]) -> JSON { JSON.from(pairs) }

// MARK: - Path reads

extension JSON {
    /// Walks a dotted path such as `"data.searchV2.tracksV2"`. Null counts as missing.
    func at(_ path: String) -> JSON? {
        var node: JSON = self
        for key in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard case .object(let o) = node, let next = o[String(key)], next != .null else { return nil }
            node = next
        }
        return node == .null ? nil : node
    }

    func obj(_ path: String) -> JSON? {
        if let n = at(path), n.isObject { return n }
        return nil
    }

    func list(_ path: String) -> [JSON] {
        if case .array(let a)? = at(path) { return a }
        return []
    }

    func str(_ path: String) -> String? {
        if case .string(let s)? = at(path) { return s }
        return nil
    }

    func long(_ path: String) -> Int64? {
        switch at(path) {
        case .int(let i)?: return i
        case .double(let d)?: return d.isFinite ? Int64(d) : nil
        case .string(let s)?: return Int64(s)
        default: return nil
        }
    }

    func int(_ path: String) -> Int? { long(path).map { Int(clamping: $0) } }

    func double(_ path: String) -> Double? {
        switch at(path) {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }

    func bool(_ path: String) -> Bool? {
        if case .bool(let b)? = at(path) { return b }
        return nil
    }

    /// `__typename` of an entity, to tell `Track` from `NotFound`.
    func typename() -> String? { str("__typename") }

    /// The elements when this node itself is an array.
    var items: [JSON] { if case .array(let a) = self { return a }; return [] }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var isObject: Bool { if case .object = self { return true }; return false }
    var isNull: Bool { self == .null }
}

// The same reads on an optional node, so a chain never needs `?.`.
extension Optional where Wrapped == JSON {
    func at(_ path: String) -> JSON? { self?.at(path) }
    func obj(_ path: String) -> JSON? { self?.obj(path) }
    func list(_ path: String) -> [JSON] { self?.list(path) ?? [] }
    func str(_ path: String) -> String? { self?.str(path) }
    func long(_ path: String) -> Int64? { self?.long(path) }
    func int(_ path: String) -> Int? { self?.int(path) }
    func double(_ path: String) -> Double? { self?.double(path) }
    func bool(_ path: String) -> Bool? { self?.bool(path) }
    func typename() -> String? { self?.typename() }
}
