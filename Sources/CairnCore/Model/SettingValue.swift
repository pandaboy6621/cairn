import Foundation

/// A portable setting value. Dates and binary data are stored as strings
/// (ISO 8601 / base64); the adapter's `type` records what they were.
public indirect enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SettingValue])
    case dict([String: SettingValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([SettingValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: SettingValue].self) { self = .dict(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported setting value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .dict(let v): try c.encode(v)
        }
    }

    /// A number as people would write it: macOS stores many settings as 32-bit
    /// floats, so 0.3 reads back as 0.30000001192092896.
    static func display(_ v: Double) -> String {
        guard v.isFinite, v != 0, abs(v) >= 1e-4, abs(v) < 1e12 else { return String(v) }
        let rounded = Double(String(format: "%.7g", v)) ?? v
        return rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int(rounded)) : String(rounded)
    }

    /// Short human-readable form for diffs and the checklist UI.
    public var summary: String {
        switch self {
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return Self.display(v)
        case .string(let v): return v.count > 60 ? "\"\(v.prefix(57))...\"" : "\"\(v)\""
        case .array(let v): return "[\(v.count) items]"
        case .dict(let v): return "{\(v.count) keys}"
        }
    }
}
