import Foundation

/// Converts property-list values into portable `SettingValue`s.
enum PlistConverter {
    /// Parses `defaults export <domain> -` output (an XML plist) into a dictionary.
    static func parseDomain(_ xml: String) throws -> [String: Any] {
        let data = Data(xml.utf8)
        guard !data.isEmpty else { return [:] }
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return object as? [String: Any] ?? [:]
    }

    /// Returns the portable value plus the adapter type name
    /// (`bool`, `int`, `float`, `string`, `date`, `data`, `array`, `dict`).
    static func convert(_ value: Any) -> (value: SettingValue, type: String)? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return (.bool(n.boolValue), "bool") }
            if CFNumberIsFloatType(n) { return (.double(n.doubleValue), "float") }
            return (.int(n.intValue), "int")
        case let s as String:
            return (.string(s), "string")
        case let d as Date:
            return (.string(iso8601.string(from: d)), "date")
        case let d as Data:
            return (.string(d.base64EncodedString()), "data")
        case let a as [Any]:
            return (.array(a.compactMap { convert($0)?.value }), "array")
        case let d as [String: Any]:
            var out: [String: SettingValue] = [:]
            for (k, v) in d { if let c = convert(v) { out[k] = c.value } }
            return (.dict(out), "dict")
        default:
            return nil
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
