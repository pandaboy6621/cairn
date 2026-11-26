import AppKit
import CairnCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar shows: the Home dashboard or one checklist category.
enum SidebarItem: Hashable {
    case home
    case sync
    case category(ChecklistCategory)

    var category: ChecklistCategory? {
        if case .category(let c) = self { return c }
        return nil
    }
}

/// A restore preview: a backup manifest compared with this Mac.
struct RestorePreview: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let backup: Manifest
    let comparison: BackupComparison
    /// Settings a restore would write that need a log out to take effect.
    let logoutSettings: [String]

    init(url: URL, backup: Manifest, current: Manifest) {
        self.url = url
        fileName = url.lastPathComponent
        self.backup = backup
        comparison = BackupComparison(backup: backup, current: current)
        logoutSettings = MacRestorer.logoutSettings(
            in: RestorePlan.make(backup: backup, current: current, manual: MacRestorer.manualStep))
    }
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
    var lastBackupURL: URL?

    /// Where "Back Up Now" saves and where restore looks for backups.
    var backupFolder: URL {
        didSet {
            defaults.set(backupFolder.path, forKey: "backupFolder")
            refreshFoundBackups()
            // A different folder has a different vault (or none).
            vault.folderChanged(self)
            // Keep automatic backups going to the same folder.
            if autoBackup != nil { setAutoBackup(true) }
            // Sync lives in the backup folder too.
            if let source = checklist?.source { sync.load(device: source.device, folder: backupFolder, scan: source) }
        }
    }
    var isDefaultBackupFolder: Bool { backupFolder.standardizedFileURL == BackupFolder.defaultURL.standardizedFileURL }
    /// Show a save panel for every backup instead of saving straight into `backupFolder`.
    var askWhereToSave: Bool {
        didSet { defaults.set(askWhereToSave, forKey: "askWhereToSave") }
    }
    /// List the backups already in `backupFolder` on the Restore card.
    var findBackupsAutomatically: Bool {
        didSet { defaults.set(findBackupsAutomatically, forKey: "findBackupsAutomatically"); refreshFoundBackups() }
    }
    /// Backups in `backupFolder`, newest first (empty when auto-find is off).
    var foundBackups: [BackupFile] = []

    /// The auto-backup agent's settings, or nil when it's off.
    var autoBackup: AutoBackupAgent.Status? = AutoBackupAgent().status
    /// Minutes between scheduled automatic backups.
    var autoBackupMinutes: Int {
        didSet { defaults.set(autoBackupMinutes, forKey: "autoBackupMinutes"); if autoBackup != nil { setAutoBackup(true) } }
    }

    /// Latest restore preview; `showingRestorePreview` drives the sheet.
    var restorePreview: RestorePreview?
    var showingRestorePreview = false
    /// The backup this app last finished restoring (the Restore card shows it as done).
    var lastRestoredURL: URL?

    /// The Sensitive tier's password and unlocked key (memory only).
    let vault = VaultFlow()
    /// Applying a restore from the preview sheet.
    let restore = RestoreRun()
    /// Open at Login.
    let loginItem = LoginItem()
    /// Sync between this Mac and others using the same backup folder.
    let sync = SyncFlow()

    /// The app's single model, for the debug snapshot hook.
    static weak var current: AppModel?

    private let defaults = UserDefaults.standard

    init() {
        let stored = UserDefaults.standard
        autoBackupMinutes = stored.object(forKey: "autoBackupMinutes") as? Int ?? AutoBackupAgent.defaultMinutes
        backupFolder = stored.string(forKey: "backupFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? BackupFolder.defaultURL
        askWhereToSave = stored.bool(forKey: "askWhereToSave")
        showInMenuBar = Self.showsMenuBarIcon
        findBackupsAutomatically = stored.object(forKey: "findBackupsAutomatically") as? Bool ?? true
        #if DEBUG
        // Snapshot runs use a scratch folder instead of the real one (didSet doesn't run in init).
        if let path = ProcessInfo.processInfo.environment["CAIRN_SNAPSHOT_BACKUP_FOLDER"] {
            backupFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        AppModel.current = self
        lastBackupDate = defaults.object(forKey: "lastBackupDate") as? Date
        lastBackupName = defaults.string(forKey: "lastBackupName")
        lastBackupURL = defaults.string(forKey: "lastBackupPath").map { URL(fileURLWithPath: $0) }
        refreshFoundBackups()
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

    /// Rescans, then syncs with the fresh scan.
    func syncNow() {
        scan { [weak self] in
            guard let self, let source = self.checklist?.source else { return }
            self.sync.syncNow(scan: source)
        }
    }

    /// Opens the restore sheet on incoming sync changes.
    func reviewIncoming(_ incoming: [SyncIncoming]) {
        guard let url = sync.prepare(incoming) else { return }
        restore.reset()
        previewRestore(url)
    }

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
    /// `then` runs on the main actor once the new checklist is in place.
    func scan(then: (@MainActor () -> Void)? = nil) {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        scanProgress = SetupScanner.Progress(completed: 0, total: SetupScanner.Source.here.count, current: nil)
        Task {
            let folder = backupFolder
            let (report, excluded) = await Task.detached(priority: .userInitiated) {
                let report = SetupScanner().scan { progress in
                    Task { @MainActor in AppModel.current?.scanProgress = progress }
                }
                // Start from what was unchecked in the last backup.
                return (report, BackupRun(folder: folder).previousExclusions(device: report.manifest.device.name))
            }.value
            var list = Checklist(manifest: report.manifest)
            vault.reloadCaptured(folder: folder, device: report.manifest.device.name)
            if vault.key == nil { vault.loadRemembered(folder: folder) }
            list.setSensitiveUnlocked(vault.exists(in: folder))
            list.checkCaptured(vault.captured)
            for id in excluded { list.setChecked(id, false) }
            previousExclusions = excluded
            checklist = list
            sync.load(device: report.manifest.device, folder: folder, scan: report.manifest)
            warnings = report.warnings
            lastScan = Date()
            isScanning = false
            scanProgress = nil
            #if DEBUG
            if restorePreview == nil, let path = ProcessInfo.processInfo.environment["CAIRN_SNAPSHOT_PREVIEW"],
               let backup = try? ManifestCoder.read(from: URL(fileURLWithPath: path)) {
                restorePreview = RestorePreview(url: URL(fileURLWithPath: path), backup: backup, current: report.manifest)
                showingRestorePreview = true
            }
            #endif
            // A restore preview compares against the scan; refresh it.
            if let preview = restorePreview {
                restorePreview = RestorePreview(url: preview.url, backup: preview.backup, current: report.manifest)
            }
            then?()
        }
    }

    // MARK: Menu bar

    /// Show Cairn's icon in the menu bar (and keep running when the window closes).
    var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Self.menuBarKey) }
    }
    static let menuBarKey = "showInMenuBar"
    static var showsMenuBarIcon: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }

    var isQuickBackingUp = false

    /// Back Up Now from the menu bar: scans first so the snapshot is current,
    /// keeping whatever the user unchecked in the window since the last backup.
    func quickBackUp() {
        guard !isQuickBackingUp, !isScanning else { return }
        isQuickBackingUp = true
        let unchecked = checklist.map { list in list.items.filter { !$0.isChecked }.map(\.id) } ?? []
        scan { [weak self] in
            guard let self else { return }
            for id in unchecked { self.checklist?.setChecked(id, false) }
            self.backUp(into: self.backupFolder) { self.isQuickBackingUp = false }
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

    /// Backs up the checked items: straight into the backup folder, or wherever the
    /// user picks when `askWhereToSave` is on.
    func backUp() {
        askWhereToSave ? backUpChoosingLocation() : backUp(into: backupFolder)
    }

    /// Always asks where to save.
    func backUpChoosingLocation() {
        guard let checklist else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up"
        panel.message = "Saves the checked items as a manifest file. Nothing on this Mac is changed."
        panel.nameFieldStringValue = BackupFolder.fileName(device: checklist.source.device.name, date: Date())
        panel.directoryURL = backupFolder
        panel.allowedContentTypes = [Self.yamlType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    /// Exclusions from the last backup, kept for items this scan didn't find.
    private var previousExclusions: [String] = []

    /// Saves a snapshot in `folder` if anything changed (used by Back Up Now and by
    /// dropping a folder). An offline NAS share queues it on this Mac instead.
    func backUp(into folder: URL, done: (@MainActor () -> Void)? = nil) {
        guard let checklist else { done?(); return }
        let ids = Set(checklist.items.map(\.id))
        // Sensitive items without a saved secret aren't a choice the user made yet.
        let captured = vault.captured
        let unchecked = checklist.items.filter {
            !$0.isChecked && ($0.category != .sensitive || captured.contains(Checklist.ref(sensitiveID: $0.id)))
        }.map(\.id)
        let excluded = Array(Set(unchecked).union(previousExclusions.filter { !ids.contains($0) }))
        let manifest = checklist.exportManifest()
        let count = checklist.checkedCount
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BackupRun(folder: folder).run(manifest, excluded: excluded, trigger: .manual) }
            }.value
            switch result {
            case .failure(let error):
                errorMessage = "Backup failed: \(error.localizedDescription)"
            case .success(let run):
                previousExclusions = excluded
                switch run.outcome {
                case .saved(let s):
                    recordBackup(s.manifestURL, name: "Snapshot \(s.id)")
                    statusMessage = "Backed up \(count) items as snapshot \(s.id) (\(s.info.summary))."
                case .unchanged(let s):
                    statusMessage = "Nothing changed since the last backup (snapshot \(s.id))."
                case .queued(let s):
                    statusMessage = "\(BackupFolder.displayPath(folder)) isn't available, so snapshot \(s.id) is saved on this Mac until it is."
                }
                if !run.flushed.isEmpty { statusMessage! += " Copied \(run.flushed.count) queued snapshot\(run.flushed.count == 1 ? "" : "s") too." }
                refreshFoundBackups()
                // Backing up is a good moment to share this Mac's changes.
                if sync.isOn, folder.standardizedFileURL == backupFolder.standardizedFileURL { sync.syncNow(scan: checklist.source) }
            }
            done?()
        }
    }

    private func recordBackup(_ url: URL, name: String) {
        lastBackupDate = Date()
        lastBackupName = name
        lastBackupURL = url
        defaults.set(lastBackupDate, forKey: "lastBackupDate")
        defaults.set(lastBackupName, forKey: "lastBackupName")
        defaults.set(url.path, forKey: "lastBackupPath")
    }

    // MARK: Automatic backups

    /// Installs or removes the auto-backup LaunchAgent, which runs the `cairn` CLI
    /// inside this app bundle.
    func setAutoBackup(_ on: Bool) {
        let agent = AutoBackupAgent()
        guard on else { agent.remove(); autoBackup = nil; return }
        let cairn = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cairn").path
        guard FileManager.default.isExecutableFile(atPath: cairn) else {
            errorMessage = "Automatic backups need the cairn tool inside Cairn.app; build the app with scripts/build-app.sh."
            return
        }
        do {
            try agent.install(cairn: cairn, folder: backupFolder, everyMinutes: autoBackupMinutes)
            autoBackup = agent.status
        } catch {
            errorMessage = "Couldn't turn on automatic backups: \(error.localizedDescription)"
        }
    }

    private func write(to url: URL) {
        guard let checklist else { return }
        do {
            try ManifestCoder.write(checklist.exportManifest(), to: url)
            recordBackup(url, name: url.lastPathComponent)
            statusMessage = "Backed up \(checklist.checkedCount) items to \(BackupFolder.displayPath(url))."
            refreshFoundBackups()
        } catch {
            errorMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// The newest backup of this Mac that still exists: the one the app saved last, or a
    /// newer one found in the backup folder (made by the CLI, automatic backups, or an
    /// earlier install), so the Back Up and Restore cards agree.
    var latestBackup: (date: Date, url: URL)? {
        let saved = lastBackupURL.flatMap { url -> (Date, URL)? in
            guard FileManager.default.fileExists(atPath: url.path), let date = lastBackupDate else { return nil }
            return (date, url)
        }
        let device = checklist?.source.device.name
        let found = foundBackups.first { device == nil || $0.deviceName == device }.map { ($0.created, $0.url) }
        switch (saved, found) {
        case let (s?, f?): return f.0 > s.0 ? f : s
        case let (s, f): return s ?? f
        }
    }

    /// The last backup file, if it still exists.
    var existingLastBackup: URL? { latestBackup?.url }

    // MARK: Backup folder

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Folder"
        panel.message = "Cairn saves backups here and looks here for backups to restore. A NAS share works too."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = backupFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupFolder = url
    }

    func resetBackupFolder() { backupFolder = BackupFolder.defaultURL }

    /// Opens the backup folder in Finder (creating the default one if needed).
    /// Makes a Windows or Linux setup kit from the checked items. Read-only here:
    /// the kit's script changes nothing until it's run with -Apply / --apply on the PC.
    func exportKit(for target: TargetPlatform) {
        guard let checklist else { return }
        let panel = NSOpenPanel()
        panel.title = "Export for \(target.title)"
        panel.message = "Choose where to put the \(target.title) setup kit: a script and a checklist. Secrets aren't included."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let kit = PlatformExport.make(checklist.exportManifest(), for: target)
        do {
            let folder = try kit.write(into: parent)
            statusMessage = "\(kit.summary). Saved to \(BackupFolder.displayPath(folder))."
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            errorMessage = "Couldn't export for \(target.title): \(error.localizedDescription)"
        }
    }

    func showBackupFolder() {
        if isDefaultBackupFolder { try? BackupFolder.ensureExists(backupFolder) }
        guard FileManager.default.fileExists(atPath: backupFolder.path) else {
            errorMessage = "\(BackupFolder.displayPath(backupFolder)) isn't available. Is the drive or NAS connected?"
            return
        }
        NSWorkspace.shared.open(backupFolder)
    }

    /// Selects a backup file in Finder.
    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func refreshFoundBackups() {
        guard findBackupsAutomatically else { foundBackups = []; return }
        let folder = backupFolder
        Task {
            let found = await Task.detached(priority: .utility) { BackupFolder.list(in: folder) }.value
            // Ignore a slow listing for a folder the user has since changed.
            if folder == backupFolder { foundBackups = found }
        }
    }

    // MARK: Restore preview

    /// Picks a manifest and compares it with this Mac. Read-only.
    func previewRestore() {
        let panel = NSOpenPanel()
        panel.title = "Preview Restore"
        panel.message = "Choose a Cairn backup to see what restoring it would change. Nothing is changed yet."
        panel.allowedContentTypes = [Self.yamlType, UTType(filenameExtension: "yml") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.directoryURL = backupFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        previewRestore(url)
    }

    /// Compares a backup file (picked, dropped, or found) with this Mac. Read-only.
    func previewRestore(_ url: URL) {
        guard let checklist else { return }
        do {
            let backup = try ManifestCoder.read(from: url)
            restore.reset()
            restorePreview = RestorePreview(url: url, backup: backup, current: checklist.source)
            showingRestorePreview = true
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error)"
        }
    }

    // MARK: Drag and drop

    /// Dropped on Back Up: a folder means "back up into this folder".
    func handleBackupDrop(_ urls: [URL]) -> Bool {
        guard let folder = urls.first(where: \.hasDirectoryPath) else {
            errorMessage = "Drop a folder here to save a backup into it."
            return false
        }
        backUp(into: folder)
        return true
    }

    /// Dropped on Restore: a backup file to preview.
    func handleRestoreDrop(_ urls: [URL]) -> Bool {
        guard let file = urls.first(where: BackupFolder.isBackupFile) else {
            errorMessage = "Drop a Cairn backup (.yaml) here to preview it."
            return false
        }
        previewRestore(file)
        return true
    }

    static let yamlType = UTType(filenameExtension: "yaml") ?? .plainText

}
