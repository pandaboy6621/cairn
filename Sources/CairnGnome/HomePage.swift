import Adwaita
import CAdw
import CairnCore
import Foundation

/// What the Home page shows (worked out by MainView).
struct HomeData {
    var checklist: Checklist?
    var scanning: Bool
    var scannedAt: Date?
    var saving: Bool
    var folder: URL
    /// This computer's snapshots, newest first.
    var myBackups: [Snapshot]
    /// Every snapshot in the folder (for Recent Backups).
    var allBackups: [Snapshot]
    var preview: HomePreview?
    var sync: SyncState
    var warnings: [String]
    /// The window is wide enough for the three cards side by side.
    var threeAcross: Bool
}

/// A backup compared with this computer, from the Restore card.
struct HomePreview {
    var snapshot: Snapshot?
    var file: URL?
    var name: String
    var comparison: BackupComparison
}

/// What the Home page's buttons and menus do.
struct HomeActions {
    var open: (Destination) -> Void
    var preferences: () -> Void
    var backUp: () -> Void
    var backUpTo: () -> Void
    var showLastBackup: () -> Void
    var openFolder: () -> Void
    var changeFolder: () -> Void
    var applyPreset: (ChecklistPreset) -> Void
    var scanAgain: () -> Void
    var previewLatest: () -> Void
    var preview: (Snapshot) -> Void
    var chooseBackupFile: () -> Void
    var showPreviewInFiles: () -> Void
    var clearPreview: () -> Void
    var refreshBackups: () -> Void
    var viewChanges: () -> Void
    var openBackups: () -> Void
    var openSync: () -> Void
    var syncNow: () -> Void
    var turnOffSync: () -> Void
}

struct HomePage: View {
    var data: HomeData
    var actions: HomeActions

    var view: Body {
        if let list = data.checklist {
            ScrollView {
                Clamp()
                    .maximumSize(1100)
                    .child {
                        VStack(spacing: 24) {
                            header(list)
                            stats(list)
                            cards(list)
                            if !data.warnings.isEmpty { warningList }
                            footnote
                        }
                        .padding(28)
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

    // MARK: Header and stats

    func header(_ list: Checklist) -> AnyView {
        HStack(spacing: 16) {
            Symbol(icon: .custom(name: "dev.cairn.Cairn"))
                .pixelSize(64)
                .iconDropshadow()
            VStack(spacing: 4) {
                Text("Your computer's setup")
                    .title1()
                    .halign(.start)
                Text(list.source.device.name + " · " + (data.scanning ? "scanning…" : data.scannedAt.map { "scanned " + Style.time($0) } ?? ""))
                    .dimLabel()
                    .halign(.start)
            }
            .valign(.center)
            .hexpand()
            Button(icon: .custom(name: "emblem-system-symbolic")) { actions.preferences() }
                .tooltip("Preferences")
                .flat()
                .circular()
                .valign(.start)
        }
    }

    struct Stat: Identifiable {
        var id: String { label }
        var value: Int
        var label: String
        var icon: String
        var tint: String
        var destination: Destination
    }

    func stats(_ list: Checklist) -> AnyView {
        let packages = list.items(in: .packages)
        let apps = packages.filter { $0.id.hasPrefix("package:flatpak:") || $0.id.hasPrefix("package:snap:") }.count
        let settingCategories: [ChecklistCategory] = [.lookAndLayout, .systemSettings, .appPreferences]
        let settings = settingCategories.reduce(0) { $0 + list.count(in: $1).total }
        let firstSettings = LinuxChecklist.categories(in: list).first { settingCategories.contains($0) } ?? .systemSettings
        let values = [
            Stat(value: packages.count - apps, label: "Packages", icon: Style.icon(.packages), tint: "tint-orange", destination: .category(.packages)),
            Stat(value: apps, label: "Flatpak and Snap apps", icon: "view-app-grid-symbolic", tint: "tint-blue", destination: .category(.packages)),
            Stat(value: settings, label: "Settings", icon: Style.icon(.systemSettings), tint: "tint-cyan", destination: .category(firstSettings)),
            Stat(value: list.checkedCount, label: "Selected", icon: "object-select-symbolic", tint: "tint-green",
                 destination: .category(LinuxChecklist.categories(in: list).first ?? .packages)),
        ]
        return HStack(spacing: 12) {
            ForEach(values) { stat in
                Button(icon: .custom(name: stat.icon)) { actions.open(stat.destination) }
                    .child {
                        HStack(spacing: 14) {
                            Symbol(icon: .custom(name: stat.icon))
                                .pixelSize(20)
                                .style("tile")
                                .style("tile-large")
                                .style(stat.tint)
                            VStack {
                                Text("\(stat.value)")
                                    .title2()
                                    .numeric()
                                    .halign(.start)
                                Text(stat.label)
                                    .ellipsize()
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

    // MARK: Cards

    enum Card: String, Identifiable, CaseIterable { case backup, restore, sync; var id: String { rawValue } }

    /// Three equal columns, stretched to the same height; stacked only when the
    /// window is too narrow for three. One box that turns, so nothing is rebuilt.
    func cards(_ list: Checklist) -> AnyView {
        Box {
            backupCard(list)
            restoreCard
            syncCard
        }
        .orientation(data.threeAcross ? .horizontal : .vertical)
        .homogeneous(data.threeAcross)
        .spacing(16)
        // Cards share the row's height (the tallest card's); the detail line
        // stretches inside each card, but the row itself doesn't grow to fill the page.
        .vexpand(false)
    }

    /// The parts every card has: a title and ⋯ menu, a status ring, a bold status,
    /// a grey detail, the buttons and a footer.
    func card(title: String, tint: String, @ViewBuilder menu: @escaping () -> Body, ring: AnyView, status: String, detail: String,
              buttons: AnyView, footer: AnyView) -> AnyView {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .title3()
                    .halign(.start)
                    .hexpand()
                Menu(icon: .custom(name: "view-more-symbolic"), content: menu)
                    .flat()
                    .tooltip("More")
            }
            ring
                .padding(4, [.top, .bottom])
            Text(status)
                .wrap()
                .maxWidthChars(18)
                .justify(.center)
                .heading()
                .halign(.center)
            Text(detail)
                .wrap()
                .maxWidthChars(22)
                .justify(.center)
                .caption()
                .dimLabel()
                .halign(.center)
            buttons
                .hexpand()
            footer
            // Cards in a row share the tallest one's height: the spare room goes
            // here, under the footer, so the button stays right under the text.
            VStack { }
                .vexpand()
        }
        .padding(20)
        .inCard("home-card")
        .style("home-card-\(tint)")
    }

    /// A status ring: `fraction` of the way round in the card's colour, with an
    /// icon or a percentage in the middle. Nil fraction: an idle (empty) ring.
    func ring(_ fraction: Double?, tint: String, icon: String?, label: String? = nil, disabled: Bool = false) -> AnyView {
        let p = fraction.map { max(0, min(100, Int(($0 * 100).rounded()))) } ?? 0
        // The hole is a horizontal box: its child gets the full height, so
        // valign centres it without anything expanding the card. Both the
        // percentage and the icon are always there and one is shown, so a ring
        // that turns from icon to percentage updates in place.
        let centre: AnyView = HStack {
            Text(label ?? "")
                .title2()
                .numeric()
                .valign(.center)
                .visible(label != nil)
            Symbol(icon: .custom(name: icon ?? "emblem-ok-symbolic"))
                .pixelSize(30)
                .style(disabled ? "dim-label" : "ring-icon-\(tint)")
                .valign(.center)
                .visible(label == nil)
        }
        return VStack {
            HStack { centre.hexpand().halign(.center) }
                .style("ring-hole")
                .padding(8)
        }
        .style("ring")
        .style(disabled ? "ring-off" : "ring-\(tint)-\(p)")
        .halign(.center)
        .valign(.center)
    }

    func footerButton(_ icon: String, _ text: String, _ action: @escaping () -> Void) -> AnyView {
        Button(icon: .custom(name: icon)) { action() }
            .child {
                HStack(spacing: 6) {
                    Symbol(icon: .custom(name: icon))
                        .pixelSize(14)
                    Text(text)
                        .ellipsize()
                        .maxWidthChars(18)
                        .caption()
                }
                .halign(.center)
            }
            .flat()
            .style("card-footer")
            .halign(.center)
    }

    func primary(_ label: String, tint: String, insensitive: Bool = false, _ action: @escaping () -> Void) -> AnyView {
        Button(label) { action() }
            .suggested()
            .style("card-button-\(tint)")
            .hexpand()
            .insensitive(insensitive)
    }

    // Back Up

    func backupCard(_ list: Checklist) -> AnyView {
        let fraction = list.items.isEmpty ? 0 : Double(list.checkedCount) / Double(list.items.count)
        let last = data.myBackups.first
        return card(title: "Back Up", tint: "teal",
                    menu: {
                        MenuSection {
                            MenuButton("Back Up To…") { actions.backUpTo() }
                            MenuButton("Backups…") { actions.openBackups() }
                            Submenu("Recent Backups") { myRecentButtons }
                            MenuButton("Show Last Backup") { actions.showLastBackup() }
                            MenuButton("Open Backup Folder") { actions.openFolder() }
                            MenuButton("Change Backup Folder…") { actions.changeFolder() }
                        }
                        MenuSection {
                            MenuButton("Choose What to Back Up") { actions.open(.category(.packages)) }
                            Submenu("Apply Preset") { presetButtons }
                            MenuButton("Scan Again") { actions.scanAgain() }
                        }
                        MenuSection {
                            MenuButton("Backup Settings…") { actions.preferences() }
                        }
                    },
                    ring: ring(data.scanning ? nil : fraction, tint: "teal",
                               icon: last == nil ? "drive-harddisk-symbolic" : "emblem-ok-symbolic"),
                    status: HomeCardText.backupStatus(checked: list.checkedCount, total: list.items.count, scanning: data.scanning),
                    detail: HomeCardText.backupDetail(lastBackup: last?.info.created),
                    buttons: HStack(spacing: 8) {
                        primary(data.saving ? "Saving…" : "Back Up Now", tint: "teal",
                                insensitive: data.saving || data.scanning || list.checkedCount == 0) { actions.backUp() }
                        Button(icon: .custom(name: "document-open-recent-symbolic")) { actions.openBackups() }
                            .tooltip("Backups")
                    },
                    footer: footerButton("folder-symbolic", "Saves to " + BackupFolder.displayPath(data.folder)) { actions.openFolder() })
    }

    var presetButtons: Body {
        ChecklistPreset.allCases.map { preset in MenuButton(preset.title) { actions.applyPreset(preset) } }
    }

    /// This computer's recent backups, each opened in Files.
    var myRecentButtons: Body {
        data.myBackups.prefix(10).map { s in
            MenuButton(BackupMessages.date(s.info.created) + (s.info.summary.isEmpty ? "" : " · " + BackupMessages.summary(s.info.summary))) {
                MainView.openInFiles(s.url)
            }
        }
    }

    var recentButtons: Body {
        data.allBackups.prefix(10).map { s in
            MenuButton(BackupMessages.date(s.info.created) + " · " + s.info.device) { actions.preview(s) }
        }
    }

    // Restore

    var restoreCard: AnyView {
        let preview = data.preview
        let latest = data.myBackups.first ?? data.allBackups.first
        let ringView: AnyView
        if let c = preview?.comparison {
            ringView = c.itemsToRestore == 0
                ? ring(1, tint: "blue", icon: "emblem-ok-symbolic")
                : ring(c.matchFraction, tint: "blue", icon: nil, label: HomeCardText.percent(c.matchFraction))
        } else {
            ringView = ring(nil, tint: "blue", icon: "document-revert-symbolic")
        }
        return card(title: "Restore", tint: "blue",
                    menu: {
                        MenuSection {
                            MenuButton("Choose Backup File…") { actions.chooseBackupFile() }
                            Submenu("Recent Backups") { recentButtons }
                            MenuButton("Show Backup in Files") { actions.showPreviewInFiles() }
                            MenuButton("Clear Preview") { actions.clearPreview() }
                        }
                        MenuSection {
                            MenuButton("Open Backup Folder") { actions.openFolder() }
                            MenuButton("Refresh Backup List") { actions.refreshBackups() }
                        }
                        MenuSection {
                            MenuButton("Restore This Backup…") { actions.viewChanges() }
                        }
                    },
                    ring: ringView,
                    status: HomeCardText.restoreStatus(comparison: preview?.comparison, backupCount: data.allBackups.count),
                    detail: HomeCardText.restoreDetail(comparedWith: preview?.name, latestDevice: latest?.info.device,
                                                       latestDate: latest?.info.created),
                    buttons: HStack(spacing: 8) {
                        if preview != nil {
                            primary("View Changes", tint: "blue") { actions.viewChanges() }
                        } else if latest != nil {
                            primary("Preview Latest", tint: "blue", insensitive: data.scanning) { actions.previewLatest() }
                        } else {
                            primary("Choose Backup…", tint: "blue") { actions.chooseBackupFile() }
                        }
                        Button(icon: .custom(name: "document-open-symbolic")) { actions.chooseBackupFile() }
                            .tooltip("Choose another backup file")
                    },
                    footer: footerButton("folder-symbolic", "Looks in " + BackupFolder.displayPath(data.folder)) { actions.openFolder() })
    }

    // Sync

    var syncCard: AnyView {
        let s = data.sync
        let pending = s.incomingCount
        let others = s.computers.filter(\.syncing).count
        let ringView = !s.enabled ? ring(nil, tint: "purple", icon: "emblem-synchronizing-symbolic", disabled: true)
            : pending > 0 ? ring(nil, tint: "purple", icon: "go-down-symbolic")
            : ring(1, tint: "purple", icon: "emblem-ok-symbolic")
        return card(title: "Sync", tint: "purple",
                    menu: {
                        MenuSection {
                            MenuButton("Open Sync") { actions.openSync() }
                            if s.enabled { MenuButton("Turn Off Sync on This Computer") { actions.turnOffSync() } }
                        }
                    },
                    ring: ringView,
                    status: HomeCardText.syncStatus(on: s.enabled, syncing: s.phase == .syncing, pending: pending, lastSync: s.lastSync),
                    detail: HomeCardText.syncDetail(on: s.enabled, others: others, lastSync: s.lastSync),
                    buttons: HStack(spacing: 8) {
                        if !s.enabled {
                            primary("Set Up Sync…", tint: "purple") { actions.openSync() }
                        } else if pending > 0 {
                            primary("Review Changes", tint: "purple") { actions.openSync() }
                        } else {
                            primary(s.phase == .syncing ? "Syncing…" : "Sync Now", tint: "purple", insensitive: s.busy) { actions.syncNow() }
                        }
                        Button(icon: .custom(name: "emblem-system-symbolic")) { actions.openSync() }
                            .tooltip("Sync settings")
                    },
                    footer: footerButton(s.enabled ? "preferences-other-symbolic" : "folder-remote-symbolic",
                                         s.enabled ? s.presetTitle + " preset" : "Through the backup folder") { actions.openSync() })
    }

    // MARK: Warnings and footnote

    var warningList: AnyView {
        FormSection("Couldn't Read") {
            Form {
                ForEach(data.warnings, id: \.self) { w in
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
            Text("Scanning and backing up are read-only. Cairn never changes your computer without showing you exactly what will change first.")
                .wrap()
                .caption()
                .dimLabel()
                .halign(.start)
                .hexpand()
        }
    }
}
