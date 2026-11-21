import AppKit
import CairnCore
import Observation
import UniformTypeIdentifiers

/// UI state over CairnCore. All real logic lives in `Checklist` and `SetupScanner`.
@MainActor @Observable
final class AppModel {
    var checklist: Checklist?
    var selectedCategory: ChecklistCategory? = .packages
    var query = ""
    var isScanning = false
    var warnings: [String] = []
    var lastScan: Date?
    var statusMessage: String?
    var errorMessage: String?
    /// Disclosure state per group name; missing means "use the default".
    var expandedGroups: [String: Bool] = [:]

    /// The app's single model, for the debug snapshot hook.
    static weak var current: AppModel?

    init() {
        AppModel.current = self
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CAIRN_SNAPSHOT_CATEGORY"], let category = ChecklistCategory(rawValue: raw) {
            selectedCategory = category
        }
        query = env["CAIRN_SNAPSHOT_QUERY"] ?? ""
        #endif
        scan()
    }

    /// Runs a read-only scan off the main thread.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        Task {
            let report = await Task.detached(priority: .userInitiated) { SetupScanner().scan() }.value
            checklist = Checklist(manifest: report.manifest)
            warnings = report.warnings
            lastScan = Date()
            isScanning = false
        }
    }

    func setChecked(_ id: String, _ value: Bool) {
        checklist?.setChecked(id, value)
    }

    func toggleAll(in category: ChecklistCategory) {
        guard let c = checklist else { return }
        let turnOn = c.state(of: category, matching: query) != .on
        checklist?.setAll(in: category, matching: query, to: turnOn)
    }

    func apply(_ preset: ChecklistPreset) {
        checklist?.apply(preset)
        statusMessage = "Applied the \(preset.title) preset."
    }

    func export() {
        guard let checklist else { return }
        let panel = NSSavePanel()
        panel.title = "Export Manifest"
        panel.message = "Only checked items are exported. Nothing on this Mac is changed."
        panel.nameFieldStringValue = "cairn-\(checklist.source.device.name).yaml"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = checklist.exportManifest()
            try ManifestCoder.write(manifest, to: url)
            statusMessage = "Exported \(checklist.checkedCount) items to \(url.lastPathComponent)."
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
