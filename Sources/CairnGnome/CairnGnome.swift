import Adwaita
import CAdw
import CairnCore
import Foundation

// WORK IN PROGRESS. Known bug: after the first state change made from a click,
// every Cairn button stops responding (GTK's own window buttons still work).
// Changes from the background scan don't trigger it. Suspect: adwaita-swift's
// `meta` dependency (tracked by branch). Debug on a real Ubuntu machine.
//
// Cairn for GNOME: a thin window over CairnCore, like the Mac app over SwiftUI.
// Read-only on this computer: scanning only reads, and backing up only writes a
// snapshot into the backup folder. Restore stays in the `cairn` CLI for now.

@main
struct CairnGnome: App {
    var app = AdwaitaApp(id: "dev.cairn.Cairn")

    var scene: Scene {
        Window(id: "main") { window in
            MainView(app: app, window: window)
        }
        .defaultSize(width: 720, height: 780)
        .title("Cairn")
        .closeShortcut()
        .quitShortcut()
    }
}

enum Page: String, CaseIterable, Equatable {
    case backup, snapshots

    var title: String { self == .backup ? "Back Up" : "Snapshots" }
    var toggleIcon: Icon? { .custom(name: self == .backup ? "document-save-symbolic" : "document-open-recent-symbolic") }
}

struct MainView: View {
    var app: AdwaitaApp
    var window: AdwaitaWindow

    @State private var page: Page = .backup
    @State private var checklist: Checklist?
    @State private var warnings: [String] = []
    @State private var scanning = false
    @State private var saving = false
    @State private var folder = AppFolder.backupFolder
    @State private var snapshots: [Snapshot] = []
    @State private var chooseFolder: Signal = .init()
    @State private var toast: Signal = .init()
    @State private var toastText = ""

    var view: Body {
        // The page changes inside a container that stays put: switching the
        // root view would rebuild the header bar and drop its buttons' handlers.
        VStack { content }
            .vexpand()
            .topToolbar {
                HeaderBar {
                    Button(icon: .custom(name: "view-refresh-symbolic")) { onMainLoop { scan() } }
                        .tooltip("Scan again")
                        .insensitive(scanning || saving)
                } end: { }
                .headerBarTitle {
                    ToggleGroup(selection: Binding { page } set: { new in onMainLoop { page = new } },
                                values: Page.allCases, id: \.self, label: \.title, icon: \.toggleIcon)
                }
            }
            .toast(toastText, signal: $toast)
            .folderImporter(open: $chooseFolder, initialFolder: folder, title: "Choose a Backup Folder",
                            acceptLabel: "Use This Folder") { url in
                folder = url
                AppFolder.backupFolder = url
                loadSnapshots()
            }
            .onAppear {
                loadSnapshots()
                scan()
            }
    }

    /// Both pages stay built and only one is shown: replacing one with the other
    /// rebuilds the window's widgets and leaves the header bar's buttons dead.
    @ViewBuilder var content: Body {
        BackupPage(checklist: $checklist, warnings: warnings, scanning: scanning, saving: saving,
                   folder: folder, chooseFolder: { chooseFolder.signal() }, backUp: backUp)
            .visible(page == .backup)
        SnapshotsPage(snapshots: snapshots, folder: folder, refresh: loadSnapshots)
            .visible(page == .snapshots)
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
            onMainLoop {
                checklist = result
                warnings = report.warnings
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

    func loadSnapshots() {
        snapshots = SnapshotStore(root: folder).list()
    }
}

// MARK: - Back Up

struct BackupPage: View {
    @Binding var checklist: Checklist?
    var warnings: [String]
    var scanning: Bool
    var saving: Bool
    var folder: URL
    var chooseFolder: () -> Void
    var backUp: () -> Void

    var view: Body {
        if let list = checklist {
            ScrollView {
                Clamp()
                    .maximumSize(720)
                    .child {
                        VStack {
                            summary(list)
                            ForEach(LinuxChecklist.categories(in: list), id: \.self) { category in
                                CategorySection(checklist: $checklist, category: category)
                            }
                            if !warnings.isEmpty {
                                FormSection("Couldn't Read") {
                                    Form {
                                        ForEach(warnings, id: \.self) { w in
                                            ActionRow(w).subtitleLines(3)
                                        }
                                    }
                                }
                                .padding()
                            }
                        }
                        .padding(12)
                    }
            }
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

    func summary(_ list: Checklist) -> AnyView {
        FormSection(list.source.device.osTitle + " · " + list.source.device.name) {
            Form {
                ActionRow("Backup folder")
                    .subtitle(BackupFolder.displayPath(folder))
                    .suffix {
                        Button("Change…") { chooseFolder() }
                            .valign(.center)
                            .flat()
                    }
                ActionRow("\(list.checkedCount) of \(list.items.count) items selected")
                    .subtitle(scanning ? "Scanning…" : "Unchecked items stay unchecked next time.")
                    .suffix {
                        Button(saving ? "Saving…" : "Back Up Now") { backUp() }
                            .suggested()
                            .valign(.center)
                            .insensitive(saving || scanning || list.checkedCount == 0)
                    }
            }
        }
        .padding()
    }
}

/// One checklist category: a switch for the whole category, then each group
/// (apt packages, Flatpak apps, ...) as its own list with a switch per item.
/// (Not expander rows: adwaita-swift drops the switches' handlers inside them.)
struct CategorySection: View {
    @Binding var checklist: Checklist?
    var category: ChecklistCategory

    var view: Body {
        if let list = checklist {
            let count = list.count(in: category)
            VStack {
                FormSection(category.title) {
                    Form {
                        SwitchRow("Include all", isOn: Binding {
                            checklist?.state(of: category) == .on
                        } set: { on in
                            checklist?.setAll(in: category, to: on)
                        })
                        .subtitle("\(count.checked) of \(count.total) selected")
                    }
                }
                .padding()
                ForEach(list.groups(in: category).map(\.name), id: \.self) { group in
                    groupSection(list, group: group)
                }
            }
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
        .padding(12, [.leading, .trailing, .bottom])
    }

    func itemRow(_ item: ChecklistItem) -> AnyView {
        SwitchRow(item.title, isOn: Binding {
            checklist?.items.first { $0.id == item.id }?.isChecked ?? false
        } set: { on in
            checklist?.setChecked(item.id, on)
        })
        .subtitle(item.detail)
    }
}

// MARK: - Snapshots

struct SnapshotsPage: View {
    var snapshots: [Snapshot]
    var folder: URL
    var refresh: () -> Void

    var view: Body {
        if snapshots.isEmpty {
            StatusPage("No Snapshots Yet", icon: .custom(name: "document-open-recent-symbolic"),
                       description: "Backups saved to \(BackupFolder.displayPath(folder)) show up here.")
                .vexpand()
        } else {
            ScrollView {
                Clamp()
                    .maximumSize(720)
                    .child {
                        FormSection(BackupFolder.displayPath(folder)) {
                            Form {
                                ForEach(snapshots.map(\.id), id: \.self) { id in
                                    row(snapshots.first { $0.id == id }!)
                                }
                            }
                        }
                        .padding(12)
                    }
            }
            .vexpand()
        }
    }

    func row(_ s: Snapshot) -> AnyView {
        ActionRow(BackupMessages.date(s.info.created))
            .subtitle("\(s.info.device) · \(s.info.summary)")
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
