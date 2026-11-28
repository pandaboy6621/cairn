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
    case home, restore, snapshots
    case category(ChecklistCategory)

    var id: String {
        switch self {
        case .home: return "home"
        case .restore: return "restore"
        case .snapshots: return "snapshots"
        case .category(let c): return c.rawValue
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .restore: return "Restore"
        case .snapshots: return "Snapshots"
        case .category(let c): return Style.title(c)
        }
    }

    var icon: String {
        switch self {
        case .home: return "user-home-symbolic"
        case .restore: return "document-revert-symbolic"
        case .snapshots: return "document-open-recent-symbolic"
        case .category(let c): return Style.icon(c)
        }
    }

    var tint: String {
        switch self {
        case .home: return "tint-blue"
        case .restore: return "tint-teal"
        case .snapshots: return "tint-green"
        case .category(let c): return Style.tint(c)
        }
    }
}

struct MainView: View {
    var app: AdwaitaApp
    var window: AdwaitaWindow

    @State private var selection: Destination = .home
    @State private var checklist: Checklist?
    @State private var apps: [String: DesktopEntry] = [:]
    @State private var warnings: [String] = []
    @State private var scanning = false
    @State private var scannedAt: Date?
    @State private var saving = false
    @State private var folder = AppFolder.backupFolder
    @State private var snapshots: [Snapshot] = []
    @State private var chooseFolder: Signal = .init()
    @State private var toast: Signal = .init()
    @State private var toastText = ""
    @State private var wide = true
    @State private var showContent = false
    @State private var restore = RestoreState()

    var destinations: [Destination] {
        let categories = checklist.map { LinuxChecklist.categories(in: $0) } ?? []
        return [.home, .restore] + categories.map { .category($0) } + [.snapshots]
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
        .alertDialog(visible: Binding { restore.confirm } set: { restore.confirm = $0 },
                     heading: "Apply This Restore?",
                     body: "Cairn will make the \(restore.report?.changeCount ?? 0) changes in the preview: add software sources, install apps and change settings. It asks for your password first. A file it replaces is kept with .before-cairn added to its name.")
        .response("Cancel", role: .close) { }
        .response("Apply", appearance: .suggested, role: .default) { onMainLoop { runRestore(apply: true) } }
        .css { Style.css }
        .folderImporter(open: $chooseFolder, initialFolder: folder, title: "Choose a Backup Folder",
                        acceptLabel: "Use This Folder") { url in
            folder = url
            AppFolder.backupFolder = url
            loadSnapshots()
        }
        .onAppear {
            Style.addIconSearchPath()
            WindowShot.scheduleIfRequested(select: { selection = $0 })
            // After the first frame: state set while the view is first built is lost.
            onMainLoop {
                loadSnapshots()
                scan()
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
        case .home, .restore: return ""
        case .snapshots: return snapshots.isEmpty ? "" : "\(snapshots.count)"
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
            HomePage(checklist: checklist, warnings: warnings, scanning: scanning, scannedAt: scannedAt,
                     saving: saving, folder: folder, snapshots: snapshots, open: go,
                     chooseFolder: { chooseFolder.signal() }, backUp: backUp)
                .visible(selection == .home)
            ForEach(destinations.compactMap { d -> ChecklistCategory? in
                if case .category(let c) = d { return c } else { return nil }
            }, id: \.self) { category in
                CategoryPage(checklist: $checklist, apps: apps, category: category)
                    .visible(selection == .category(category))
            }
            SnapshotsPage(snapshots: snapshots, folder: folder, chooseFolder: { chooseFolder.signal() })
                .visible(selection == .snapshots)
            RestorePage(snapshots: restoreChoices, state: restore,
                        select: { id in restore.snapshotID = id; restore.phase = .idle; restore.report = nil },
                        preview: { onMainLoop { runRestore(apply: false) } },
                        askToApply: { restore.confirm = true })
                .visible(selection == .restore)
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
        case .restore: return restore.running ? (restore.phase == .applying ? "Applying…" : "Previewing…") : ""
        case .snapshots: return BackupFolder.displayPath(folder)
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
            }
        }
    }

    func backUp() {
        guard let list = checklist, !saving else { return }
        saving = true
        let folder = folder
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
        guard !restore.running, let snapshot = restoreChoices.first(where: { $0.id == restore.snapshotID }) ?? restoreChoices.first else { return }
        restore.snapshotID = snapshot.id
        restore.phase = apply ? .applying : .previewing
        restore.lastLine = ""
        let folder = folder
        Task.detached {
            var helper: URL?
            defer { if let helper { try? FileManager.default.removeItem(at: helper) } }
            do {
                let manifest = try SnapshotStore(root: folder).manifest(of: snapshot)
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
                    }
                }
            } catch {
                let message = "Couldn't run the restore: \(error.localizedDescription)"
                onMainLoop { restore.phase = .failed(message) }
            }
        }
    }

    func loadSnapshots() {
        snapshots = SnapshotStore(root: folder).list()
    }
}

// MARK: - Home

struct HomePage: View {
    var checklist: Checklist?
    var warnings: [String]
    var scanning: Bool
    var scannedAt: Date?
    var saving: Bool
    var folder: URL
    var snapshots: [Snapshot]
    var open: (Destination) -> Void
    var chooseFolder: () -> Void
    var backUp: () -> Void

    struct Stat: Identifiable {
        var id: String { label }
        var value: String
        var label: String
        var icon: String
        var tint: String
        var destination: Destination
    }

    var view: Body {
        if let list = checklist {
            ScrollView {
                Clamp()
                    .maximumSize(820)
                    .child {
                        VStack(spacing: 24) {
                            header(list)
                            stats(list)
                            backupCard(list)
                            if !warnings.isEmpty { warningList }
                            footnote
                        }
                        .padding(24, [.leading, .trailing])
                        .padding(28, [.top, .bottom])
                    }
            }
            .hscrollbarPolicy(.never)
            .vexpand()
        } else {
            StatusPage("Scanning This Computer", icon: .custom(name: "system-search-symbolic"),
                       description: "Looking at your apps, settings and config files. Nothing is changed.") {
                Spinner()
                    .frame(minWidth: 32)
                    .halign(.center)
            }
            .vexpand()
        }
    }

    func header(_ list: Checklist) -> AnyView {
        HStack(spacing: 18) {
            Symbol(icon: .custom(name: "dev.cairn.Cairn"))
                .pixelSize(72)
                .iconDropshadow()
            VStack(spacing: 4) {
                Text("Your computer's setup")
                    .title1()
                    .halign(.start)
                Text([list.source.device.name, scannedAt.map { "scanned " + Style.time($0) }].compactMap { $0 }
                        .joined(separator: " · "))
                    .dimLabel()
                    .halign(.start)
            }
            .valign(.center)
        }
    }

    func stats(_ list: Checklist) -> AnyView {
        let packages = list.count(in: .packages).total
        let settingCategories: [ChecklistCategory] = [.lookAndLayout, .systemSettings, .appPreferences]
        let settings = settingCategories.reduce(0) { $0 + list.count(in: $1).total }
        let firstSettings = LinuxChecklist.categories(in: list).first { settingCategories.contains($0) } ?? .systemSettings
        let values = [
            Stat(value: "\(packages)", label: packages == 1 ? "App" : "Apps", icon: Style.icon(.packages),
                 tint: Style.tint(.packages), destination: .category(.packages)),
            Stat(value: "\(settings)", label: settings == 1 ? "Setting" : "Settings", icon: Style.icon(.systemSettings),
                 tint: "tint-cyan", destination: .category(firstSettings)),
            Stat(value: "\(list.checkedCount)", label: "Selected", icon: "object-select-symbolic",
                 tint: "tint-green", destination: .category(LinuxChecklist.categories(in: list).first ?? .packages)),
            Stat(value: "\(snapshots.count)", label: snapshots.count == 1 ? "Snapshot" : "Snapshots",
                 icon: "document-open-recent-symbolic", tint: "tint-purple", destination: .snapshots),
        ]
        return HStack(spacing: 12) {
            ForEach(values) { stat in
            Button(icon: .custom(name: stat.icon)) { open(stat.destination) }
                .child {
                    HStack(spacing: 14) {
                        Symbol(icon: .custom(name: stat.icon))
                            .pixelSize(20)
                            .style("tile")
                            .style("tile-large")
                            .style(stat.tint)
                        VStack {
                            Text(stat.value)
                                .title2()
                                .numeric()
                                .halign(.start)
                            Text(stat.label)
                                .caption()
                                .dimLabel()
                                .halign(.start)
                        }
                        .valign(.center)
                    }
                    .halign(.start)
                }
                .style("stat-card")
                .hexpand()
            }
        }
    }

    func backupCard(_ list: Checklist) -> AnyView {
        let last = snapshots.first.map { "Last backup " + BackupMessages.date($0.info.created) + "." }
            ?? "No backups yet."
        return VStack(spacing: 10) {
            Symbol(icon: .custom(name: "drive-harddisk-symbolic"))
                .pixelSize(40)
                .style("hero-ring")
                .halign(.center)
            Text("Back Up")
                .title2()
                .padding(6, [.top])
            Text("\(list.checkedCount) of \(list.items.count) items selected")
                .heading()
                .style("teal-text")
            Text(last + " Saves a snapshot of the apps and settings you selected, never your files.")
                .wrap()
                .justify(.center)
                .dimLabel()
                .frame(maxWidth: 440)
            Button(saving ? "Saving…" : "Back Up Now") { backUp() }
                .pill()
                .suggested()
                .style("teal-button")
                .halign(.center)
                .padding(8, [.top])
                .insensitive(saving || scanning || list.checkedCount == 0)
            HStack(spacing: 6) {
                Symbol(icon: .custom(name: "folder-symbolic"))
                    .pixelSize(14)
                    .dimLabel()
                Text("Saves to " + BackupFolder.displayPath(folder))
                    .ellipsize()
                    .caption()
                    .dimLabel()
                Button("Change…") { chooseFolder() }
                    .flat()
                    .style("small-link")
            }
            .halign(.center)
        }
        .padding(28)
        .inCard("backup-card")
    }

    var warningList: AnyView {
        FormSection("Couldn't Read") {
            Form {
                ForEach(warnings, id: \.self) { w in
                    ActionRow(w)
                        .subtitleLines(3)
                        .prefix {
                            Symbol(icon: .custom(name: "dialog-warning-symbolic"))
                                .warning()
                        }
                }
            }
        }
    }

    var footnote: AnyView {
        HStack(spacing: 8) {
            Symbol(icon: .custom(name: "security-high-symbolic"))
                .pixelSize(14)
                .dimLabel()
                .valign(.start)
            Text("Scanning and backing up only read this computer. Cairn never changes it without showing you exactly what will change first.")
                .wrap()
                .caption()
                .dimLabel()
                .halign(.start)
                .hexpand()
        }
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
