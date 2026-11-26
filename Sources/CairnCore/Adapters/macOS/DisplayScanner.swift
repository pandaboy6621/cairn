#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One display as the OS reports it, before Cairn turns it into a `DisplayItem`.
public struct RawDisplay: Equatable, Sendable {
    /// The OS's handle for the display (a `CGDirectDisplayID`). Not stable across Macs.
    public var displayID: UInt32
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var builtin: Bool
    public var main: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshHz: Double
    public var rotation: Double
    /// `displayID` of the display this one mirrors, or 0.
    public var mirrorOf: UInt32

    public init(
        displayID: UInt32, vendor: UInt32, model: UInt32, serial: UInt32, builtin: Bool = false, main: Bool = false,
        x: Double, y: Double, width: Double, height: Double, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
        refreshHz: Double = 0, rotation: Double = 0, mirrorOf: UInt32 = 0
    ) {
        self.displayID = displayID
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.builtin = builtin
        self.main = main
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth ?? Int(width)
        self.pixelHeight = pixelHeight ?? Int(height)
        self.refreshHz = refreshHz
        self.rotation = rotation
        self.mirrorOf = mirrorOf
    }
}

/// Reads (and, for restore, changes) the display arrangement. The real one is
/// `CoreGraphicsDisplays`; tests pass a fake.
public protocol DisplaySystem: Sendable {
    func onlineDisplays() -> [RawDisplay]
    /// Each display's desktop picture path, keyed by `RawDisplay.displayID`.
    func desktopPictures() -> [UInt32: String]
    /// Sets a display's desktop picture (current Space). Writes system state.
    func setDesktopPicture(_ path: String, display: UInt32) throws
}

extension DisplaySystem {
    public func desktopPictures() -> [UInt32: String] { [:] }
    public func setDesktopPicture(_ path: String, display: UInt32) throws {
        throw CommandError.failed(command: "set desktop picture", exitCode: 1, stderr: "not supported")
    }
}

/// Reports no displays: Linux, which has no display reader yet.
public struct NoDisplays: DisplaySystem {
    public init() {}
    public func onlineDisplays() -> [RawDisplay] { [] }
}

#if os(macOS)
public typealias DefaultDisplays = CoreGraphicsDisplays
#else
public typealias DefaultDisplays = NoDisplays
#endif

/// Records how monitors are arranged. Read-only.
public struct DisplayScanner: SetupScanning {
    public var system: DisplaySystem

    public init(system: DisplaySystem = DefaultDisplays()) {
        self.system = system
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let raw = system.onlineDisplays()
        guard !raw.isEmpty else {
            out.warnings.append("displays: no displays reported")
            return out
        }
        var names: [String: String] = [:]
        do {
            names = Self.parseNames(try runner.output(Command("system_profiler", ["SPDisplaysDataType", "-json"])))
        } catch {
            out.warnings.append("displays: couldn't read display names: \(error)")
        }
        out.displays = DisplayLayout(displays: Self.items(raw, names: names))
        // Wallpaper comes from the same displays, so it shares their ids.
        let ids = Self.identities(raw)
        let pictures = system.desktopPictures().compactMap { display, path in
            ids[display].map { DesktopPicture(display: $0, path: path) }
        }
        if !pictures.isEmpty { out.wallpaper = WallpaperLayout(pictures: pictures.sorted { $0.display < $1.display }) }
        return out
    }

    /// Turns raw displays into manifest items with stable ids and positions
    /// relative to the main display.
    public static func items(_ raw: [RawDisplay], names: [String: String] = [:]) -> [DisplayItem] {
        let ids = identities(raw)
        let main = raw.first(where: \.main) ?? raw[0]
        return raw.map { r in
            DisplayItem(
                id: ids[r.displayID]!,
                name: name(for: r, names: names),
                builtin: r.builtin,
                main: r.displayID == main.displayID,
                x: Int((r.x - main.x).rounded()),
                y: Int((r.y - main.y).rounded()),
                width: Int(r.width.rounded()),
                height: Int(r.height.rounded()),
                pixelWidth: r.pixelWidth,
                pixelHeight: r.pixelHeight,
                refreshHz: r.refreshHz > 0 ? (r.refreshHz * 100).rounded() / 100 : nil,
                rotation: Int(r.rotation.rounded()) % 360,
                mirrorOf: r.mirrorOf == 0 ? nil : ids[r.mirrorOf]
            )
        }
    }

    /// Maps each display to its manifest id. Monitors without a serial number
    /// share `<vendor>-<model>`, so repeats get `-2`, `-3`, ... left to right.
    public static func identities(_ raw: [RawDisplay]) -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        var used: [String: Int] = [:]
        for r in raw.sorted(by: { ($0.x, $0.y, $0.displayID) < ($1.x, $1.y, $1.displayID) }) {
            var id = baseID(r)
            used[id, default: 0] += 1
            if used[id]! > 1 { id += "-\(used[id]!)" }
            result[r.displayID] = id
        }
        return result
    }

    static func baseID(_ r: RawDisplay) -> String {
        if r.builtin { return "builtin" }
        let model = "\(hex(r.vendor))-\(hex(r.model))"
        guard r.serial != 0 else { return model }
        // Hash the serial: identical monitors stay distinct without recording the real number.
        let digest = SHA256.hash(data: Data("\(r.vendor)-\(r.model)-\(r.serial)".utf8))
        return model + "-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func name(for r: RawDisplay, names: [String: String]) -> String {
        if let n = names[hex(r.displayID)] ?? names["\(hex(r.vendor))-\(hex(r.model))"], !n.isEmpty, n != "Color LCD" {
            return n
        }
        return r.builtin ? "Built-in display" : "Display \(hex(r.vendor))-\(hex(r.model))"
    }

    /// Parses `system_profiler SPDisplaysDataType -json` into display names,
    /// keyed by display id (hex) and by `<vendor>-<model>` (hex).
    public static func parseNames(_ json: String) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let gpus = root["SPDisplaysDataType"] as? [[String: Any]]
        else { return [:] }
        var names: [String: String] = [:]
        for gpu in gpus {
            for d in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                guard let name = d["_name"] as? String else { continue }
                if let id = d["_spdisplays_displayID"] as? String {
                    names[id.lowercased()] = name
                }
                if let v = d["_spdisplays_display-vendor-id"] as? String,
                   let p = d["_spdisplays_display-product-id"] as? String {
                    names["\(v.lowercased())-\(p.lowercased())"] = name
                }
            }
        }
        return names
    }

    static func hex(_ n: UInt32) -> String { String(n, radix: 16) }
}
