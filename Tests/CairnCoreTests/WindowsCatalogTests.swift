import Foundation
import Testing
@testable import CairnCore

/// The Windows app (windows/) sets up from Mac backups with the same names as the
/// Windows kit, read from windows/Cairn.Core/catalog.json. This keeps that file in
/// step with PackageCatalog and TaskbarPins. After editing either, regenerate it:
///
///     CAIRN_WRITE_CATALOG=1 swift test --filter WindowsCatalogTests
@Suite struct WindowsCatalogTests {
    static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("windows/Cairn.Core/catalog.json")

    static func generate() throws -> String {
        func winget(_ table: [String: PackageNames]) -> [String: String] { table.compactMapValues(\.winget) }
        let catalog: [String: Any] = [
            "about": "Generated from Sources/CairnCore/Platforms (PackageCatalog, TaskbarPins) by WindowsCatalogTests. Don't edit by hand.",
            "formulae": winget(PackageCatalog.formulae),
            "casks": winget(PackageCatalog.casks),
            "mac_only": PackageCatalog.macOnly.sorted(),
            "office_suites": PackageCatalog.officeSuites.sorted(),
            "office_casks": PackageCatalog.officeCasks.sorted(),
            "office_apps": PackageCatalog.officeApps.sorted(),
            "taskbar_mac_only": TaskbarPins.macOnly.sorted(),
            "taskbar_renamed": TaskbarPins.renamed,
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    @Test func windowsCatalogIsCurrent() throws {
        let fresh = try Self.generate()
        if ProcessInfo.processInfo.environment["CAIRN_WRITE_CATALOG"] == "1" {
            try fresh.write(to: Self.file, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: Self.file, encoding: .utf8)
        #expect(committed == fresh, "windows/Cairn.Core/catalog.json is out of date: run CAIRN_WRITE_CATALOG=1 swift test --filter WindowsCatalogTests")
    }
}
