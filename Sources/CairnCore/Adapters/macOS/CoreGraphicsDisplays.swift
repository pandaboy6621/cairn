import CoreGraphics
import Foundation

/// The macOS display system, through public CoreGraphics APIs.
public struct CoreGraphicsDisplays: DisplaySystem {
    public init() {}

    public func onlineDisplays() -> [RawDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { d in
            // Asleep or lid-closed screens are online but not active; they have no place in the layout.
            guard CGDisplayIsActive(d) != 0 || CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay else { return nil }
            let bounds = CGDisplayBounds(d)
            let mode = CGDisplayCopyDisplayMode(d)
            return RawDisplay(
                displayID: d,
                vendor: CGDisplayVendorNumber(d),
                model: CGDisplayModelNumber(d),
                serial: CGDisplaySerialNumber(d),
                builtin: CGDisplayIsBuiltin(d) != 0,
                main: CGDisplayIsMain(d) != 0,
                x: bounds.origin.x, y: bounds.origin.y,
                width: bounds.width, height: bounds.height,
                pixelWidth: mode?.pixelWidth ?? Int(bounds.width),
                pixelHeight: mode?.pixelHeight ?? Int(bounds.height),
                refreshHz: mode?.refreshRate ?? 0,
                rotation: CGDisplayRotation(d),
                mirrorOf: CGDisplayMirrorsDisplay(d)
            )
        }
    }

    public enum ApplyError: Error, CustomStringConvertible {
        case displayGone(String)
        case failed(String, CGError)

        public var description: String {
            switch self {
            case .displayGone(let name): return "\(name) was disconnected before the change could be made"
            case .failed(let what, let err): return "\(what) failed (CoreGraphics error \(err.rawValue))"
            }
        }
    }

    /// Writes system state: rearranges displays. Only the restore path calls this,
    /// after the plan has been shown. `permanently: false` lasts until logout.
    /// Returns warnings for steps that couldn't be done (e.g. no matching mode).
    @discardableResult
    public func apply(_ plan: DisplayPlan, permanently: Bool = true) throws -> [String] {
        guard !plan.steps.isEmpty else { return [] }
        let raw = onlineDisplays()
        let byID = Dictionary(DisplayScanner.identities(raw).map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var warnings: [String] = []

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw ApplyError.failed("Starting the display change", .failure)
        }
        var done = false
        defer { if !done { CGCancelDisplayConfiguration(config) } }

        for step in plan.steps {
            guard let d = byID[step.displayID] else { throw ApplyError.displayGone(step.displayName) }
            let err: CGError
            switch step.action {
            case let .move(x, y):
                err = CGConfigureDisplayOrigin(config, d, Int32(x), Int32(y))
            case let .mirror(of):
                let source = of.flatMap { byID[$0] } ?? kCGNullDirectDisplay
                err = CGConfigureDisplayMirrorOfDisplay(config, d, source)
            case let .setMode(w, h, pw, ph, hz):
                guard let mode = Self.mode(for: d, width: w, height: h, pixelWidth: pw, pixelHeight: ph, refreshHz: hz) else {
                    warnings.append("\(step.displayName): no \(w)×\(h) mode available, resolution left as is")
                    continue
                }
                err = CGConfigureDisplayWithDisplayMode(config, d, mode, nil)
            }
            guard err == .success else { throw ApplyError.failed("\(step.displayName): \(step.summary)", err) }
        }

        let err = CGCompleteDisplayConfiguration(config, permanently ? .permanently : .forSession)
        done = true
        guard err == .success else { throw ApplyError.failed("Applying the display change", err) }
        return warnings
    }

    static func mode(for d: CGDirectDisplayID, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshHz: Double?) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(d, options) as? [CGDisplayMode]) ?? []
        let sized = modes.filter {
            $0.width == width && $0.height == height && $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight
        }
        guard let hz = refreshHz else { return sized.max { $0.refreshRate < $1.refreshRate } }
        return sized.min { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) }
    }
}
