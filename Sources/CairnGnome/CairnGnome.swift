import Adwaita
import CAdw
import CairnCore
import Foundation

// Cairn for GNOME: a thin window over CairnCore, like the Mac app over SwiftUI.
// Read-only on this computer: scanning only reads, and backing up only writes a
// snapshot into the backup folder. Restore stays in the `cairn` CLI for now.
//
// Note: in a container over GTK Broadway, Cairn's buttons stopped responding
// after the first click that changed state. On a real GNOME Wayland desktop
// (Ubuntu 26.04) clicks keep working, so that was a Broadway quirk. Test the
// app on a real desktop, not over Broadway.

@main
struct CairnGnome: App {
    var app: AdwaitaApp

    init() {
        // sudo runs `cairn-gnome --askpass` to ask for the password during a restore.
        if CommandLine.arguments.contains("--askpass") { exit(Askpass.run()) }
        // Opened as an AppImage: put Cairn in the app grid so it needn't be found in a terminal.
        AppImageIntegration.integrateIfNeeded()
        app = AdwaitaApp(id: "dev.cairn.Cairn")
    }

    var scene: Scene {
        Window(id: "main") { window in
            MainView(app: app, window: window)
        }
        .defaultSize(width: 1000, height: 720)
        .title("Cairn")
        .closeShortcut()
        .quitShortcut()
    }
}

/// A page in the sidebar.
enum Destination: Hashable, Identifiable {
    case home
    case category(ChecklistCategory)

    var id: String {
        switch self {
        case .home: return "home"
        case .category(let c): return c.rawValue
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .category(let c): return Style.title(c)
        }
    }

    var icon: String {
        switch self {
        case .home: return "user-home-symbolic"
        case .category(let c): return Style.icon(c)
        }
    }

    var tint: String {
        switch self {
        case .home: return "tint-blue"
        case .category(let c): return Style.tint(c)
        }
    }
}

struct MainView: View {
    var app: AdwaitaApp
    var window: AdwaitaWindow

    @State var selection: Destination = .home
    @State var checklist: Checklist?
    @State var apps: [String: DesktopEntry] = [:]
    @State var warnings: [String] = []
    @State var scanning = false
    @State var scannedAt: Date?
    @State var saving = false
    @State var folder = AppFolder.backupFolder
    @State var snapshots: [Snapshot] = []
    @State var chooseFolder: Signal = .init()
    @State var toast: Signal = .init()
    @State var toastText = ""
    @State var wide = true
    @State var showContent = false
    @State var restore = RestoreState()
    @State var sync = SyncState()
    @State var chooseSyncFolder: Signal = .init()
    @State var homePreview: HomePreview?
    @State var homeWide = true
    @State var showBackups = false
    @State var showRestore = false
    @State var showSync = false
    @State var preferences = false
    @State var backUpToFolder: Signal = .init()
    @State var chooseBackupFile: Signal = .init()

    var destinations: [Destination] {
        let categories = checklist.map { LinuxChecklist.categories(in: $0) } ?? []
        return [.home] + categories.map { .category($0) }
    }

    var view: Body {
        NavigationSplitView {
            sidebar
                .navigationTitle("Cairn")
        } content: {
            content
                .navigationTitle(selection.title)
        }
        .collapsed(!wide)
        .showContent($showContent)
        .breakpoint(minWidth: 680, matches: $wide)
        .toast(toastText, signal: $toast)
        .dialog(visible: $showBackups, title: "Backups", width: 640, height: 720) {
            SnapshotsPage(snapshots: snapshots, folder: folder, chooseFolder: { chooseFolder.signal() })
                .topToolbar { HeaderBar.empty() }
        }
        .dialog(visible: $showRestore, title: "Restore", width: 760, height: 820) {
            RestorePage(snapshots: restoreChoices, state: restore,
                        select: { id in restore.snapshotID = id; restore.file = nil; restore.phase = .idle; restore.report = nil },
                        clearFile: { restore.file = nil; restore.phase = .idle; restore.report = nil },
                        preview: { onMainLoop { runRestore(apply: false) } },
                        askToApply: { restore.confirm = true })
                .topToolbar { HeaderBar.empty() }
            .alertDialog(visible: Binding { restore.confirm } set: { restore.confirm = $0 },
                         heading: "Apply This Restore?",
                         body: "Cairn will make the \(restore.report?.changeCount ?? 0) changes in the preview: add software sources, install apps and change settings. It asks for your password first. A file it replaces is kept with .before-cairn added to its name.")
            .response("Cancel", role: .close) { }
            .response("Apply", appearance: .suggested, role: .default) { onMainLoop { runRestore(apply: true) } }
        }
        .dialog(visible: $showSync, title: "Sync", width: 760, height: 820) {
            SyncPage(state: sync, actions: syncActions)
                .topToolbar { HeaderBar.empty() }
            .alertDialog(visible: Binding { sync.confirm } set: { sync.confirm = $0 },
                         heading: "Apply Changes from Your Other Computers?",
                         body: "Cairn will make the \(sync.report?.changeCount ?? 0) changes in the preview on this computer. It asks for your password first.")
            .response("Cancel", role: .close) { }
            .response("Apply", appearance: .suggested, role: .default) { onMainLoop { runSyncRestore(apply: true) } }
        }
        .folderImporter(open: $backUpToFolder, initialFolder: folder, title: "Back Up To",
                        acceptLabel: "Back Up Here") { url in backUp(to: url) }
        .fileImporter(open: $chooseBackupFile, initialFolder: folder, title: "Choose a Backup File",
                      acceptLabel: "Preview") { url in previewFile(url) }
        .preferencesDialog(visible: $preferences)
        .preferencesPage("General", icon: .custom(name: "emblem-system-symbolic")) { page in
            page
                .group("Backups") {
                    ActionRow("Backup folder")
                        .subtitle(BackupFolder.displayPath(folder))
                        .suffix {
                            Button("Change…") { preferences = false; chooseFolder.signal() }
                                .flat()
                                .valign(.center)
                        }
                    ActionRow("Backups found")
                        .subtitle(snapshots.isEmpty ? "None in this folder yet"
                                  : "\(snapshots.count) in this folder, from \(Set(snapshots.map(\.info.device)).count) computer\(Set(snapshots.map(\.info.device)).count == 1 ? "" : "s")")
                    ActionRow("Find backups automatically")
                        .subtitle("Cairn looks for backups in the backup folder, including ones from your other computers.")
                }
                .group("Sync") {
                    ActionRow("Sync")
                        .subtitle(sync.enabled ? "On, through " + (sync.folder.map { BackupFolder.displayPath($0) } ?? "the backup folder") : "Off")
                        .suffix {
                            Button("Open Sync") { preferences = false; showSync = true }
                                .flat()
                                .valign(.center)
                        }
                }
        }
        .folderImporter(open: $chooseSyncFolder, initialFolder: sync.folder ?? folder, title: "Choose the Sync Folder",
                        acceptLabel: "Sync Through This Folder") { url in setSyncFolder(url) }
        .css { Style.css }
        .folderImporter(open: $chooseFolder, initialFolder: folder, title: "Choose a Backup Folder",
                        acceptLabel: "Use This Folder") { url in
            folder = url
            AppFolder.backupFolder = url
            loadSnapshots()
        }
        .onAppear {
            Style.addIconSearchPath()
            WindowShot.scheduleIfRequested(select: { page in
                switch page {
                case "backups": showBackups = true
                case "restore": showRestore = true
                case "restore-preview": homeActions.previewLatest(); onMainLoop { openRestore() }
                case "sync": showSync = true
                case "home": selection = .home
                default: if let c = ChecklistCategory(rawValue: page) { selection = .category(c) }
                }
            })
            // After the first frame: state set while the view is first built is lost.
            onMainLoop {
                loadSnapshots()
                scan()
                loadSync()
                // Three cards across from about 900 pixels of window.
                WindowWidth.watch { width in
                    let wide = width >= 900
                    if wide != homeWide { homeWide = wide }
                }
            }
        }
    }

    func go(_ d: Destination) {
        selection = d
        showContent = true
    }

    // MARK: Sidebar

    @ViewBuilder var sidebar: Body {
        VStack {
            deviceHeader
            ScrollView {
                List(destinations, id: \.id, selection: Binding { selection.id } set: { id in
                    if let d = destinations.first(where: { $0.id == id }), d != selection { go(d) }
                }) { d in
                    sidebarRow(d)
                }
                .sidebarStyle()
            }
            .hscrollbarPolicy(.never)
            .vexpand()
            selectedMeter
        }
        .topToolbar {
            HeaderBar.empty()
                .headerBarTitle { WindowTitle(subtitle: "", title: "Cairn") }
        }
    }

    var deviceHeader: AnyView {
        HStack(spacing: 12) {
            Symbol(icon: .custom(name: "computer-symbolic"))
                .pixelSize(22)
                .style("device-icon")
            VStack {
                Text(checklist?.source.device.name ?? "This computer")
                    .ellipsize()
                    .heading()
                    .halign(.start)
                Text(checklist?.source.device.osTitle ?? "Linux")
                    .ellipsize()
                    .caption()
                    .dimLabel()
                    .halign(.start)
            }
            .valign(.center)
        }
        .padding(16, [.leading, .trailing])
        .padding(8, [.top, .bottom])
    }

    func sidebarRow(_ d: Destination) -> AnyView {
        HStack(spacing: 12) {
            Symbol(icon: .custom(name: d.icon))
                .pixelSize(16)
                .style("tile")
                .style(d.tint)
            Text(d.title)
                .ellipsize()
                .halign(.start)
                .hexpand()
            Text(badge(d))
                .style("count-badge")
                .numeric()
                .visible(!badge(d).isEmpty)
        }
        .padding(6, [.top, .bottom])
        .padding(4, [.leading, .trailing])
    }

    func badge(_ d: Destination) -> String {
        switch d {
        case .home: return ""
        case .category(let c): return checklist.map { "\($0.count(in: c).total)" } ?? ""
        }
    }

    var selectedMeter: AnyView {
        let checked = checklist?.checkedCount ?? 0, total = checklist?.items.count ?? 0
        return VStack(spacing: 10) {
            HStack {
                Text("Selected for backup")
                    .captionHeading()
                    .halign(.start)
                    .hexpand()
                Text("\(checked) of \(total)")
                    .caption()
                    .numeric()
                    .dimLabel()
            }
            ProgressBar(value: Double(checked), total: Double(max(total, 1)))
                .style("teal-progress")
        }
        .padding(14)
        .inCard("card")
        .padding(12)
    }

    // MARK: Content

    @ViewBuilder var content: Body {
        VStack {
            HomePage(data: homeData, actions: homeActions)
                .visible(selection == .home)
            ForEach(destinations.compactMap { d -> ChecklistCategory? in
                if case .category(let c) = d { return c } else { return nil }
            }, id: \.self) { category in
                CategoryPage(checklist: $checklist, apps: apps, category: category)
                    .visible(selection == .category(category))
            }
        }
        .vexpand()
        .topToolbar {
            HeaderBar {
                Button(icon: .custom(name: "view-refresh-symbolic")) { onMainLoop { scan() } }
                    .tooltip("Scan again")
                    .insensitive(scanning || saving)
            } end: {
                Spinner()
                    .visible(scanning || saving)
            }
            .headerBarTitle {
                WindowTitle(subtitle: subtitle, title: selection.title)
            }
        }
    }

    var subtitle: String {
        if scanning { return "Scanning…" }
        if saving { return "Saving…" }
        guard let list = checklist else { return "" }
        switch selection {
        case .home: return scannedAt.map { "Scanned at " + Style.time($0) } ?? ""
        case .category(let c):
            let n = list.count(in: c)
            return "\(n.checked) of \(n.total) selected"
        }
    }

    // MARK: Actions

    /// Scans off the main loop (it runs apt, flatpak, snap, gsettings), then
    /// shows the checklist with last time's unchecked items still unchecked.
    func scan() {
        guard !scanning else { return }
        scanning = true
        let folder = folder
        Task.detached {
            let report = SetupScanner().scan()
            let excluded = BackupRun(folder: folder).previousExclusions(device: report.manifest.device.name)
            var list = Checklist(manifest: report.manifest)
            for id in excluded { list.setChecked(id, false) }
            let result = list
            var found: [String: DesktopEntry] = [:]
            for item in result.items {
                if let p = ItemLabels.package(itemID: item.id), let entry = DesktopEntries.lookup(kind: p.kind, id: p.id) {
                    found[item.id] = entry
                }
            }
            let entries = found
            onMainLoop {
                checklist = result
                apps = entries
                warnings = report.warnings
                scannedAt = Date()
                scanning = false
                refreshHomePreview()
            }
        }
    }

    func backUp(to target: URL? = nil) {
        guard let list = checklist, !saving else { return }
        saving = true
        let folder = target ?? folder
        Task.detached {
            let message: String
            do {
                let excluded = list.items.filter { !$0.isChecked }.map(\.id).sorted()
                let result = try BackupRun(folder: folder).run(list.exportManifest(), excluded: excluded, trigger: .manual)
                message = BackupMessages.describe(result.outcome, folder: folder)
            } catch {
                message = "Couldn't save the backup: \(error.localizedDescription)"
            }
            onMainLoop {
                saving = false
                toastText = message
                toast.signal()
                loadSnapshots()
            }
        }
    }

    /// Snapshots a restore can use: this computer's first, then the others in the folder.
    var restoreChoices: [Snapshot] {
        let me = checklist?.source.device.name ?? ""
        return snapshots.filter { $0.info.device == me } + snapshots.filter { $0.info.device != me }
    }

    /// Runs the kit for the chosen snapshot: a dry run, or for real with the
    /// password asked by Cairn's own window (sudo -A).
    func runRestore(apply: Bool) {
        let file = restore.file
        let snapshot = restoreChoices.first(where: { $0.id == restore.snapshotID }) ?? restoreChoices.first
        guard !restore.running, file != nil || snapshot != nil else { return }
        if file == nil { restore.snapshotID = snapshot?.id }
        restore.phase = apply ? .applying : .previewing
        restore.lastLine = ""
        let folder = folder
        Task.detached {
            var helper: URL?
            defer { if let helper { try? FileManager.default.removeItem(at: helper) } }
            do {
                let manifest = try file.map { try ManifestCoder.read(from: $0) } ?? SnapshotStore(root: folder).manifest(of: snapshot!)
                var askpass: String?
                if apply {
                    let h = try Askpass.helper()
                    askpass = h.path
                    helper = h.folder
                }
                let result = try LinuxRestoreRun(manifest: manifest).run(apply: apply, askpass: askpass) { line in
                    guard line.hasPrefix("  ") else { return }
                    onMainLoop { restore.lastLine = line }
                }
                onMainLoop {
                    restore.report = result.report
                    restore.doByHand = result.doByHand
                    restore.phase = apply ? .applied : .previewed
                    if apply {
                        toastText = result.report.failed.isEmpty ? "Restore finished" : "Restore finished with problems"
                        toast.signal()
                        // This computer just changed: scan it again, which also redoes the card's comparison.
                        scan()
                    }
                }
            } catch {
                let message = "Couldn't run the restore: \(error.localizedDescription)"
                onMainLoop { restore.phase = .failed(message) }
            }
        }
    }

    // MARK: Home

    var mySnapshots: [Snapshot] {
        let me = checklist?.source.device.name ?? ""
        return snapshots.filter { $0.info.device == me }
    }

    var homeData: HomeData {
        HomeData(checklist: checklist, scanning: scanning, scannedAt: scannedAt, saving: saving, folder: folder,
                 myBackups: mySnapshots, allBackups: snapshots, preview: homePreview, sync: sync, warnings: warnings,
                 threeAcross: homeWide)
    }

    var homeActions: HomeActions {
        HomeActions(open: go,
                    preferences: { preferences = true },
                    backUp: { backUp() },
                    backUpTo: { backUpToFolder.signal() },
                    showLastBackup: { if let s = mySnapshots.first { Self.openInFiles(s.url) } },
                    openFolder: { Self.openInFiles(folder) },
                    changeFolder: { chooseFolder.signal() },
                    applyPreset: { preset in checklist?.apply(preset) },
                    scanAgain: { onMainLoop { scan() } },
                    previewLatest: { if let s = restoreChoices.first { previewSnapshot(s) } },
                    preview: { previewSnapshot($0) },
                    chooseBackupFile: { chooseBackupFile.signal() },
                    showPreviewInFiles: {
                        if let p = homePreview { Self.openInFiles(p.snapshot?.url ?? p.file?.deletingLastPathComponent() ?? folder) }
                    },
                    clearPreview: { homePreview = nil },
                    refreshBackups: { loadSnapshots() },
                    viewChanges: { openRestore() },
                    openBackups: { showBackups = true },
                    openSync: { showSync = true },
                    syncNow: { onMainLoop { syncNow() } },
                    turnOffSync: { setSync(false) })
    }

    static func openInFiles(_ url: URL) {
        g_app_info_launch_default_for_uri(url.absoluteString, nil, nil)
    }

    /// The Restore card's quick comparison: the backup against this scan, the
    /// same BackupComparison the Mac uses, so the numbers match.
    func previewSnapshot(_ s: Snapshot) {
        guard let current = checklist?.source else { return }
        let folder = folder
        Task.detached {
            guard let backup = try? SnapshotStore(root: folder).manifest(of: s) else { return }
            let c = BackupComparison(backup: backup, current: current)
            let name = BackupMessages.date(s.info.created) + " · " + s.info.device
            onMainLoop { homePreview = HomePreview(snapshot: s, file: nil, name: name, comparison: c) }
        }
    }

    /// After a scan, the Restore card's comparison is redone against the new scan,
    /// so it never shows numbers from before a restore.
    func refreshHomePreview() {
        guard let p = homePreview else { return }
        if let s = p.snapshot { previewSnapshot(s) } else if let f = p.file { previewFile(f) }
    }

    func previewFile(_ url: URL) {
        guard let current = checklist?.source else { return }
        do {
            let backup = try ManifestCoder.read(from: url)
            homePreview = HomePreview(snapshot: nil, file: url, name: url.lastPathComponent,
                                      comparison: BackupComparison(backup: backup, current: current))
        } catch {
            toastText = "That isn't a Cairn backup: \(error.localizedDescription)"
            toast.signal()
        }
    }

    /// "View Changes": the Restore page with the previewed backup, previewing.
    func openRestore() {
        if let p = homePreview {
            restore.snapshotID = p.snapshot?.id
            restore.file = p.file
        }
        restore.phase = .idle
        restore.report = nil
        showRestore = true
        onMainLoop { runRestore(apply: false) }
    }

    func loadSnapshots() {
        snapshots = SnapshotStore(root: folder).list()
    }
}

// MARK: - Category

/// One checklist category: a switch for the whole category, then each group
/// (Flatpak apps, Snaps, ...) as its own list with a switch per item.
/// (Not expander rows: adwaita-swift drops the switches' handlers inside them.)
struct CategoryPage: View {
    @Binding var checklist: Checklist?
    var apps: [String: DesktopEntry]
    var category: ChecklistCategory

    var view: Body {
        if let list = checklist {
            let count = list.count(in: category)
            ScrollView {
                Clamp()
                    .maximumSize(720)
                    .child {
                        VStack(spacing: 24) {
                            PageHeader(title: Style.title(category), blurb: Style.blurb(category),
                                       icon: Style.icon(category), tint: Style.tint(category))
                            Form {
                                SwitchRow("Include all", isOn: Binding {
                                    checklist?.state(of: category) == .on
                                } set: { on in
                                    checklist?.setAll(in: category, to: on)
                                })
                                .subtitle("\(count.checked) of \(count.total) selected")
                            }
                            ForEach(list.groups(in: category).map(\.name), id: \.self) { group in
                                groupSection(list, group: group)
                            }
                        }
                        .padding(24, [.leading, .trailing])
                        .padding(28, [.top, .bottom])
                    }
            }
            .hscrollbarPolicy(.never)
            .vexpand()
        }
    }

    func groupSection(_ list: Checklist, group: String) -> AnyView {
        let items = list.groups(in: category).first { $0.name == group }?.items ?? []
        return FormSection(group) {
            Form {
                ForEach(items.map(\.id), id: \.self) { id in
                    itemRow(items.first { $0.id == id }!)
                }
            }
        }
    }

    func itemRow(_ item: ChecklistItem) -> AnyView {
        let label = Style.label(for: item, apps: apps)
        return SwitchRow(label.title, isOn: Binding {
            checklist?.items.first { $0.id == item.id }?.isChecked ?? false
        } set: { on in
            checklist?.setChecked(item.id, on)
        })
        .subtitle(label.subtitle)
        .inspect { storage, _ in
            Style.setRowIcon(storage, name: label.icon, appIcon: label.isAppIcon, tint: Style.tint(category))
        }
    }
}

/// A page's title with its colored icon tile and a sentence about it.
struct PageHeader: View {
    var title: String
    var blurb: String
    var icon: String
    var tint: String

    var view: Body {
        HStack(spacing: 16) {
            Symbol(icon: .custom(name: icon))
                .pixelSize(24)
                .style("tile")
                .style("tile-xl")
                .style(tint)
                .valign(.center)
            VStack(spacing: 2) {
                Text(title)
                    .title2()
                    .halign(.start)
                Text(blurb)
                    .wrap()
                    .dimLabel()
                    .halign(.start)
            }
            .valign(.center)
            .hexpand()
        }
    }
}

// MARK: - Snapshots

struct SnapshotsPage: View {
    var snapshots: [Snapshot]
    var folder: URL
    var chooseFolder: () -> Void

    var view: Body {
        if snapshots.isEmpty {
            StatusPage("No Snapshots Yet", icon: .custom(name: "document-open-recent-symbolic"),
                       description: "Backups saved to \(BackupFolder.displayPath(folder)) show up here.") {
                Button("Choose Another Folder…") { chooseFolder() }
                    .pill()
                    .halign(.center)
            }
            .vexpand()
        } else {
            ScrollView {
                Clamp()
                    .maximumSize(720)
                    .child {
                        VStack(spacing: 24) {
                            PageHeader(title: "Snapshots",
                                       blurb: "Each backup is kept as a snapshot, so you can see what changed and go back.",
                                       icon: "document-open-recent-symbolic", tint: "tint-green")
                            FormSection(BackupFolder.displayPath(folder)) {
                                Form {
                                    ForEach(snapshots.map(\.id), id: \.self) { id in
                                        row(snapshots.first { $0.id == id }!, latest: id == snapshots.first?.id)
                                    }
                                }
                            }
                            .suffix {
                                Button("Change…") { chooseFolder() }
                                    .flat()
                                    .valign(.center)
                            }
                        }
                        .padding(24, [.leading, .trailing])
                        .padding(28, [.top, .bottom])
                    }
            }
            .hscrollbarPolicy(.never)
            .vexpand()
        }
    }

    func row(_ s: Snapshot, latest: Bool) -> AnyView {
        ActionRow(BackupMessages.date(s.info.created))
            .subtitle("\(s.info.device) · \(BackupMessages.summary(s.info.summary))")
            .prefix {
                Symbol(icon: .custom(name: latest ? "emblem-ok-symbolic" : "document-save-symbolic"))
                    .pixelSize(16)
                    .style("tile")
                    .style(latest ? "tint-green" : "tint-gray")
                    .valign(.center)
            }
            .suffix {
                Text("Latest")
                    .style("count-badge")
                    .style("badge-green")
                    .valign(.center)
                    .visible(latest)
            }
    }
}

// MARK: - Helpers

extension AnyView {
    /// Draws `style` (a card background) behind this view including its padding:
    /// adwaita-swift's padding is a margin, so styling the padded view itself
    /// would leave the content touching the card's edge.
    func inCard(_ style: String) -> AnyView {
        VStack { self }
            .style(style)
    }
}

// MARK: - Main loop

/// Runs `body` on GTK's main thread from any thread. `g_idle_add` is thread-safe;
/// adwaita-swift's `Idle` is main-actor-only, so it can't be called from a background task.
func onMainLoop(_ body: @escaping @MainActor () -> Void) {
    final class Box { let body: @MainActor () -> Void; init(_ b: @escaping @MainActor () -> Void) { body = b } }
    let context = Unmanaged.passRetained(Box(body)).toOpaque()
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, { pointer in
        guard let pointer else { return 0 }
        let box = Unmanaged<Box>.fromOpaque(pointer).takeRetainedValue()
        MainActor.assumeIsolated { box.body() }
        return 0 // G_SOURCE_REMOVE: run once
    }, context, nil)
}
