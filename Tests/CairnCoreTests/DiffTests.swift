import Foundation
import Testing
@testable import CairnCore

@Suite struct ManifestDiffTests {
    @Test func identicalManifestsHaveNoDiff() {
        #expect(ManifestDiff.between(Samples.manifest, Samples.manifest).isEmpty)
    }

    @Test func ignoresDeviceAndCreated() {
        var b = Samples.manifest
        b.device.name = "other"
        b.created = Date()
        #expect(ManifestDiff.between(Samples.manifest, b).isEmpty)
    }

    @Test func reportsAddedRemovedAndChanged() {
        let a = Samples.manifest
        var b = a
        b.packages.removeAll { $0.uid == "formula:wget" }
        b.packages.append(PackageItem(id: "jq", kind: .formula, resolvers: ["brew": "jq"]))
        b.settings[0].value = .bool(false) // dock.autohide true → false
        b.apps[0].include = false

        let diff = ManifestDiff.between(a, b)
        let packages = diff.sections.first { $0.name == "packages" }
        #expect(packages?.added == ["formula:jq"])
        #expect(packages?.removed == ["formula:wget"])

        let settings = diff.sections.first { $0.name == "settings" }
        #expect(settings?.changed == [ManifestDiff.Change(id: "dock.autohide", from: "true", to: "false")])

        let apps = diff.sections.first { $0.name == "apps" }
        #expect(apps?.changed == [ManifestDiff.Change(id: "497799835 include", from: "true", to: "false")])
    }

    @Test func formulaAndCaskWithSameNameAreDistinct() {
        let a = Samples.manifest
        var b = a
        b.packages.removeAll { $0.uid == "cask:docker" }
        let packages = ManifestDiff.between(a, b).sections.first { $0.name == "packages" }
        #expect(packages?.removed == ["cask:docker"])
    }

    @Test func detectsDockReorder() {
        let a = Samples.manifest
        var b = a
        b.layout.dock?.apps = ["/System/Applications/Mail.app", "spacer", "/Applications/Safari.app"]
        let dock = ManifestDiff.between(a, b).sections.first { $0.name == "layout.dock" }
        #expect(dock?.added == [] && dock?.removed == [])
        #expect(dock?.changed.first?.id == "order")
        #expect(dock?.changed.first?.to == "Mail, spacer, Safari")
    }

    @Test func rendersReadableText() {
        var b = Samples.manifest
        b.settings[0].value = .bool(false)
        let text = ManifestDiff.between(Samples.manifest, b).render()
        #expect(text == "settings (+0 -0 ~1)\n  ~ dock.autohide: true → false\n")
        #expect(ManifestDiff(sections: []).render() == "No differences.\n")
    }
}
