import AppKit
import CairnCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar shows: the Home dashboard or one checklist category.
enum SidebarItem: Hashable {
    case home
    case category(ChecklistCategory)

    var category: ChecklistCategory? {
        if case .category(let c) = self { return c }
        return nil
    }
}

/// A restore preview: a backup manifest compared with this Mac.
struct RestorePreview: Identifiable {
    let id = UUID()
    let fileName: String
    let backup: Manifest
    let comparison: BackupComparison
}

/// UI state over CairnCore. All real logic lives in `Checklist`, `SetupScanner`,
/// and `BackupComparison`.
@MainActor @Observable
final class AppModel {
    var checklist: Checklist?
    var selection: SidebarItem? = .home
    var query = ""
    var isScanning = false
    var scanProgress: SetupScanner.Progress?
    var warnings: [String] = []
    var lastScan: Date?
    var statusMessage: String?
    var errorMessage: String?
    /// Disclosure state per group name; missing means "use the default".
    var expandedGroups: [String: Bool] = [:]

    /// Most recent export ("backup"), remembered across launches.
    var lastBackupDate: Date?
    var lastBackupName: String?

    /// Latest restore preview; `showingRestorePreview` drives the sheet.
    var restorePreview: RestorePreview?
    var showingRestorePreview = false

    /// The app's single model, for the debug snapshot hook.
    static weak var current: AppModel?

    private let defaults = UserDefaults.standard

    init() {
        AppModel.current = self
        lastBackupDate = defaults.object(forKey: "lastBackupDate") as? Date
        lastBackupName = defaults.string(forKey: "lastBackupName")
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CAIRN_SNAPSHOT_CATEGORY"], let category = ChecklistCategory(rawValue: raw) {
            selection = .category(category)
        }
        query = env["CAIRN_SNAPSHOT_QUERY"] ?? ""
        #endif
        scan()
    }

    var selectedCategory: ChecklistCategory? { selection?.category }

    /// A running task, shown as a small ring by the device name. Backup, restore,
    /// and sync tasks plug in here as they arrive.
    struct Activity {
        var label: String
        var symbol: String
        var tint: Color
        /// nil = no measurable progress (the ring spins).
        var fraction: Double?
    }

    var activity: Activity? {
        if isScanning {
            let label = scanProgress?.current.map { "Reading \($0.title)…" } ?? "Scanning…"
            return Activity(label: label, symbol: "magnifyingglass", tint: .teal, fraction: scanProgress?.fraction)
        }
        return nil
    }

    // MARK: Scan

    /// Runs a read-only scan off the main thread, reporting progress.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        scanProgress = SetupScanner.Progress(completed: 0, total: SetupScanner.Source.allCases.count, current: nil)
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                SetupScanner().scan { progress in
                    Task { @MainActor in AppModel.current?.scanProgress = progress }
                }
            }.value
            checklist = Checklist(manifest: report.manifest)
            warnings = report.warnings
            lastScan = Date()
            isScanning = false
            scanProgress = nil
            #if DEBUG
            if restorePreview == nil, let path = ProcessInfo.processInfo.environment["CAIRN_SNAPSHOT_PREVIEW"],
               let backup = try? ManifestCoder.read(from: URL(fileURLWithPath: path)) {
                restorePreview = RestorePreview(fileName: URL(fileURLWithPath: path).lastPathComponent, backup: backup,
                                                comparison: BackupComparison(backup: backup, current: report.manifest))
                showingRestorePreview = true
            }
            #endif
            // A restore preview compares against the scan; refresh it.
            if let preview = restorePreview {
                restorePreview = RestorePreview(
                    fileName: preview.fileName, backup: preview.backup,
                    comparison: BackupComparison(backup: preview.backup, current: report.manifest))
            }
        }
    }

    // MARK: Checklist

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

    // MARK: Backup (export)

    func export() {
        guard let checklist else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up"
        panel.message = "Saves the checked items as a manifest file. Nothing on this Mac is changed."
        panel.nameFieldStringValue = "cairn-\(checklist.source.device.name)-\(Self.fileDate.string(from: Date())).yaml"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ManifestCoder.write(checklist.exportManifest(), to: url)
            lastBackupDate = Date()
            lastBackupName = url.lastPathComponent
            defaults.set(lastBackupDate, forKey: "lastBackupDate")
            defaults.set(lastBackupName, forKey: "lastBackupName")
            statusMessage = "Backed up \(checklist.checkedCount) items to \(url.lastPathComponent)."
        } catch {
            errorMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    // MARK: Restore preview

    /// Picks a manifest and compares it with this Mac. Read-only.
    func previewRestore() {
        guard let checklist else { return }
        let panel = NSOpenPanel()
        panel.title = "Preview Restore"
        panel.message = "Choose a Cairn backup to see what restoring it would change. Nothing is changed yet."
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText, UTType(filenameExtension: "yml") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try ManifestCoder.read(from: url)
            restorePreview = RestorePreview(
                fileName: url.lastPathComponent, backup: backup,
                comparison: BackupComparison(backup: backup, current: checklist.source))
            showingRestorePreview = true
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error)"
        }
    }

    private static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
