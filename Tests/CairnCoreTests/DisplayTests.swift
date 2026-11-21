import Foundation
import Testing
@testable import CairnCore

@Suite struct DisplayScannerTests {
    @Test func recordsArrangementRelativeToMain() throws {
        let found = try DisplayScanner(system: Fixtures.displays).scan(using: Fixtures.fullRunner())
        let displays = try #require(found.displays).displays
        let laptop = try #require(displays.first { $0.builtin })
        let monitor = try #require(displays.first { !$0.builtin })

        #expect(laptop.id == "builtin")
        #expect(laptop.name == "Built-in display") // "Color LCD" is replaced
        #expect(laptop.main && (laptop.x, laptop.y) == (0, 0))
        #expect((laptop.width, laptop.pixelWidth, laptop.refreshHz) == (1512, 3024, 120))

        #expect(monitor.name == "Example 27 Monitor")
        #expect((monitor.x, monitor.y) == (-2560, -300))
        #expect(!monitor.main)
        #expect(found.warnings.isEmpty)
    }

    @Test func hashesSerialNumbers() {
        let id = DisplayScanner.baseID(RawDisplay(displayID: 4, vendor: 0x1e6d, model: 0x5b10, serial: 12345, x: 0, y: 0, width: 1, height: 1))
        #expect(id.hasPrefix("1e6d-5b10-"))
        #expect(!id.contains("12345") && !id.contains(String(12345, radix: 16)))
    }

    @Test func identicalMonitorsWithoutSerialsGetDistinctIDs() {
        let raw = [
            RawDisplay(displayID: 7, vendor: 0x10, model: 0x20, serial: 0, x: 1920, y: 0, width: 1920, height: 1080),
            RawDisplay(displayID: 3, vendor: 0x10, model: 0x20, serial: 0, main: true, x: 0, y: 0, width: 1920, height: 1080),
        ]
        let ids = DisplayScanner.identities(raw)
        #expect(ids[3] == "10-20")   // leftmost
        #expect(ids[7] == "10-20-2")
    }

    @Test func positionsAreRelativeToTheMainDisplay() {
        // Some systems report the main display away from (0, 0).
        let raw = [
            RawDisplay(displayID: 1, vendor: 1, model: 1, serial: 1, main: true, x: 100, y: 50, width: 1000, height: 800),
            RawDisplay(displayID: 2, vendor: 2, model: 2, serial: 2, x: 1100, y: 50, width: 1000, height: 800, rotation: 90, mirrorOf: 0),
        ]
        let items = DisplayScanner.items(raw)
        #expect(items.map { [$0.x, $0.y] } == [[0, 0], [1000, 0]])
        #expect(items[1].rotation == 90)
    }

    @Test func mirroringPointsAtTheSourceID() {
        let raw = [
            RawDisplay(displayID: 1, vendor: 0, model: 0, serial: 0, builtin: true, main: true, x: 0, y: 0, width: 1512, height: 982),
            RawDisplay(displayID: 2, vendor: 5, model: 6, serial: 0, x: 0, y: 0, width: 1512, height: 982, mirrorOf: 1),
        ]
        #expect(DisplayScanner.items(raw).first { !$0.builtin }?.mirrorOf == "builtin")
    }

    @Test func missingNamesAreOnlyAWarning() throws {
        let found = try DisplayScanner(system: Fixtures.displays).scan(using: FixtureRunner())
        #expect(found.displays?.displays.count == 2)
        #expect(found.warnings.count == 1)
    }

    @Test func parsesNamesByIDAndModel() {
        let names = DisplayScanner.parseNames(Fixtures.text("displays.json"))
        #expect(names["4"] == "Example 27 Monitor")
        #expect(names["1e6d-5b10"] == "Example 27 Monitor")
        #expect(DisplayScanner.parseNames("not json").isEmpty)
    }

    @Test func roundTripsThroughYAML() throws {
        var m = Manifest(device: Device(name: "t", os: "macos", osVersion: "14.5"), created: Date(timeIntervalSince1970: 0))
        m.layout.displays = DisplayLayout(displays: DisplayScanner.items(Fixtures.displays.displays))
        let yaml = try ManifestCoder.encode(m)
        #expect(yaml.contains("pixel_width: 3024"))
        #expect(try ManifestCoder.decode(yaml) == m.normalized())
    }

    @Test func oldManifestsWithoutDisplaysStillLoad() throws {
        let yaml = "schema: 1\ndevice: { name: t, os: macos, os_version: '14.5' }\ncreated: 2026-11-21T10:00:00Z\nlayout: { dock: { apps: [], include: true } }\n"
        #expect(try ManifestCoder.decode(yaml).layout.displays == nil)
    }
}

@Suite struct DisplayPlanTests {
    static let laptop = DisplayItem(id: "builtin", name: "Built-in display", builtin: true, main: true,
                                    x: 0, y: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshHz: 120)
    static let left = DisplayItem(id: "10-20-aaaa", name: "Left", x: -1920, y: 0, width: 1920, height: 1080, refreshHz: 60)
    static let right = DisplayItem(id: "10-20-bbbb", name: "Right", x: 1512, y: 0, width: 1920, height: 1080, refreshHz: 60)

    @Test func matchingLayoutNeedsNothing() {
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, Self.left]), current: [Self.laptop, Self.left])
        #expect(plan.isEmpty && plan.manual.isEmpty)
        #expect(plan.render() == "Displays already match the saved layout.\n")
    }

    @Test func movesDisplaysBackIntoPlace() {
        var swapped = Self.left
        swapped.x = 1512
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, Self.left]), current: [Self.laptop, swapped])
        #expect(plan.steps.map(\.action) == [.move(x: -1920, y: 0)])
        #expect(plan.steps.first?.displayID == "10-20-aaaa")
    }

    @Test func savedMainDisplayEndsUpAtOrigin() {
        // Saved: the external monitor was main, laptop to its right and lower.
        var mainMonitor = Self.left
        mainMonitor.main = true; mainMonitor.x = 0
        var laptopRight = Self.laptop
        laptopRight.main = false; laptopRight.x = 1920; laptopRight.y = 98
        // Now: the laptop is main with the monitor on its left.
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [mainMonitor, laptopRight]), current: [Self.laptop, Self.left])
        #expect(Set(plan.steps.map(\.action)) == [.move(x: 0, y: 0), .move(x: 1920, y: 98)])
    }

    @Test func sameModelOnANewMacStillMatches() {
        // Same kind of monitor, different unit (different serial hash).
        var other = Self.left
        other.id = "10-20-cccc"; other.x = 1512
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, Self.left]), current: [Self.laptop, other])
        #expect(plan.matches.contains(.init(saved: "10-20-aaaa", current: "10-20-cccc")))
        #expect(plan.steps.map(\.action) == [.move(x: -1920, y: 0)])
    }

    @Test func identicalMonitorsMatchTheirOwnSerials() {
        // Two identical monitors swapped on the desk: each must go back to its own place.
        var l = Self.left, r = Self.right
        l.x = Self.right.x; r.x = Self.left.x
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, Self.left, Self.right]), current: [Self.laptop, l, r])
        let moves = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.displayID, $0.action) })
        #expect(moves["10-20-aaaa"] == .move(x: -1920, y: 0))
        #expect(moves["10-20-bbbb"] == .move(x: 1512, y: 0))
    }

    @Test func missingAndExtraDisplays() {
        let stranger = DisplayItem(id: "99-99", name: "Projector", x: 1512, y: 0, width: 1280, height: 720)
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, Self.left]), current: [Self.laptop, stranger])
        #expect(plan.isEmpty)
        #expect(plan.manual == ["Left isn't connected, so its saved position was skipped."])
        #expect(plan.untouched == ["Projector"])
    }

    @Test func changesResolution() {
        var scaled = Self.laptop
        scaled.width = 1800; scaled.height = 1169
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [scaled]), current: [Self.laptop])
        #expect(plan.steps.map(\.action) == [.setMode(width: 1800, height: 1169, pixelWidth: 3024, pixelHeight: 1964, refreshHz: 120)])
    }

    @Test func rotationIsLeftToTheUser() {
        var portrait = Self.left
        portrait.rotation = 90; portrait.width = 1080; portrait.height = 1920
        let plan = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, portrait]), current: [Self.laptop, Self.left])
        #expect(!plan.steps.contains { if case .setMode = $0.action { return true } else { return false } })
        #expect(plan.manual.first?.hasPrefix("Rotate Left to 90°") == true)
    }

    @Test func restoresAndStopsMirroring() {
        var mirror = Self.left
        mirror.mirrorOf = "builtin"; mirror.x = 0
        let toMirror = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, mirror]), current: [Self.laptop, Self.left])
        #expect(toMirror.steps.map(\.action) == [.mirror(of: "builtin")])

        let toExtend = DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, Self.left]), current: [Self.laptop, mirror])
        #expect(Set(toExtend.steps.map(\.action)) == [.mirror(of: nil), .move(x: -1920, y: 0)])
    }

    @Test func refreshRateRoundingIsIgnored() {
        var close = Self.left
        close.refreshHz = 59.94
        #expect(DisplayPlan.make(saved: DisplayLayout(displays: [Self.laptop, Self.left]), current: [Self.laptop, close]).isEmpty)
    }
}

@Suite struct DisplayDiffAndChecklistTests {
    static func manifest(_ displays: [DisplayItem]) -> Manifest {
        var m = Manifest(device: Device(name: "t", os: "macos", osVersion: "14.5"), created: Date(timeIntervalSince1970: 0))
        m.layout.displays = DisplayLayout(displays: displays)
        return m
    }

    @Test func diffShowsMovedAndAddedDisplays() {
        var moved = DisplayPlanTests.left
        moved.x = 1512
        let diff = ManifestDiff.between(Self.manifest([DisplayPlanTests.laptop, DisplayPlanTests.left]),
                                        Self.manifest([DisplayPlanTests.laptop, moved, DisplayPlanTests.right]))
        let section = diff.sections.first { $0.name == "layout.displays" }
        #expect(section?.added == ["Right (10-20-bbbb)"])
        #expect(section?.changed.map(\.id) == ["Left position"])
    }

    @Test func checklistHasOneDisplayItem() {
        var checklist = Checklist(manifest: Self.manifest([DisplayPlanTests.laptop, DisplayPlanTests.left]))
        let item = checklist.items.first { $0.id == "layout:displays" }
        #expect(item?.category == .lookAndLayout)
        #expect(item?.detail == "2 displays · main: Built-in display")
        #expect(checklist.exportManifest().layout.displays?.displays.count == 2)

        checklist.setChecked("layout:displays", false)
        #expect(checklist.exportManifest().layout.displays == nil)
    }

    @Test func restorePreviewCountsTheLayoutAsOneItem() {
        var moved = DisplayPlanTests.left
        moved.x = 1512
        let comparison = BackupComparison(backup: Self.manifest([DisplayPlanTests.laptop, DisplayPlanTests.left]),
                                          current: Self.manifest([DisplayPlanTests.laptop, moved]))
        #expect(comparison.backupItemCount == 1)
        #expect(comparison.itemsToRestore == 1)
    }
}
