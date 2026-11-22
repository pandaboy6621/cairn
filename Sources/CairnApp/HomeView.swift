import CairnCore
import SwiftUI

/// The Home dashboard: setup stats plus Back Up, Restore, and Sync cards.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Header()
                StatsRow()
                HStack(alignment: .top, spacing: 16) {
                    BackupCard()
                    RestoreCard()
                    SyncCard()
                }
                Footnote()
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Header and stats

private struct Header: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Mac's setup")
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
    }

    private var subtitle: String {
        let name = DeviceInfo.friendlyName
        if model.isScanning { return "\(name) · scanning…" }
        guard let lastScan = model.lastScan else { return name }
        return "\(name) · scanned \(lastScan.formatted(date: .omitted, time: .shortened))"
    }
}

private struct StatsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let m = model.checklist?.source
        HStack(spacing: 12) {
            StatTile(value: m.map { "\($0.packages.count)" }, label: "Packages", category: .packages)
            StatTile(value: m.map { "\($0.apps.count)" }, label: "App Store apps", category: .appStore)
            StatTile(value: m.map { "\($0.settings.count)" }, label: "Settings", category: .systemSettings,
                     symbol: "slider.horizontal.3", tint: .teal)
            StatTile(value: model.checklist.map { "\($0.checkedCount)" }, label: "Selected",
                     category: nil, symbol: "checkmark.circle", tint: .green)
        }
    }
}

private struct StatTile: View {
    @Environment(AppModel.self) private var model
    let value: String?
    let label: String
    let category: ChecklistCategory?
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        Button {
            if let category { model.selection = .category(category) }
        } label: {
            HStack(spacing: 12) {
                SymbolTile(symbol: symbol ?? category?.symbol ?? "circle",
                           tint: tint ?? category?.tint ?? .gray, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value ?? "–")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(CardBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(category.map { "Show \($0.title)" } ?? "")
    }
}

// MARK: - Cards

private struct BackupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DashboardCard(
            title: "Back Up",
            tint: .teal,
            ring: ring,
            status: status,
            detail: detail,
            footer: { FolderRow(caption: "Saves to") },
            dropHint: "Drop a folder to back up into it",
            onDrop: model.checklist == nil || model.isScanning ? nil : { model.handleBackupDrop($0) }
        ) {
            HStack(spacing: 8) {
                Button {
                    model.backUp()
                } label: {
                    Label(model.askWhereToSave ? "Back Up Now…" : "Back Up Now", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(model.checklist == nil || model.isScanning)

                if let last = model.existingLastBackup {
                    Button {
                        model.showInFinder(last)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Show \(last.lastPathComponent) in Finder")
                }
            }
        } menu: {
            Button("Back Up To…") { model.backUpChoosingLocation() }
                .disabled(model.checklist == nil || model.isScanning)
            if let last = model.existingLastBackup {
                Button("Show Last Backup in Finder") { model.showInFinder(last) }
            }
            Button("Open Backup Folder") { model.showBackupFolder() }
            Button("Change Backup Folder…") { model.chooseBackupFolder() }
            Divider()
            Button("Choose What to Back Up") { model.selection = .category(.packages) }
            Menu("Apply Preset") {
                ForEach(ChecklistPreset.allCases) { preset in
                    Button(preset.title) { model.apply(preset) }
                }
            }
            Button("Scan Again") { model.scan() }
                .disabled(model.isScanning)
            Divider()
            SettingsLink { Text("Backup Settings…") }
        }
    }

    private var ring: RingState {
        if model.isScanning {
            let p = model.scanProgress
            return .progress(p?.fraction ?? 0, symbol: "magnifyingglass", label: nil)
        }
        guard let c = model.checklist else { return .idle(symbol: "externaldrive") }
        let fraction = c.items.isEmpty ? 0 : Double(c.checkedCount) / Double(c.items.count)
        return .progress(fraction, symbol: model.latestBackup == nil ? "externaldrive" : "externaldrive.badge.checkmark",
                         label: nil)
    }

    private var status: String {
        if model.isScanning {
            if let current = model.scanProgress?.current { return "Reading \(current.title)…" }
            return "Scanning…"
        }
        guard let c = model.checklist else { return "Not scanned yet" }
        return "\(c.checkedCount) of \(c.items.count) items selected"
    }

    private var detail: String {
        if let date = model.latestBackup?.date {
            return "Last backup \(date.formatted(.relative(presentation: .named)))"
        }
        return "No backups yet. Saves a manifest file you can restore from."
    }
}

private struct RestoreCard: View {
    @Environment(AppModel.self) private var model

    /// This app finished restoring this backup.
    private func restored(_ p: RestorePreview) -> Bool { model.lastRestoredURL == p.url.standardizedFileURL }

    var body: some View {
        let preview = model.restorePreview
        let latest = model.foundBackups.first
        let busy = model.checklist == nil || model.isScanning
        DashboardCard(
            title: "Restore",
            tint: .blue,
            // Matching, or just restored: a full ring with a checkmark, so it never
            // reads as a restore stuck part way.
            ring: preview.map { p in
                let left = p.comparison.itemsToRestore
                return left == 0 || restored(p) ? .progress(1, symbol: "checkmark", label: nil)
                    : .progress(p.comparison.matchFraction, symbol: nil,
                                label: "\(Int((p.comparison.matchFraction * 100).rounded()))%")
            } ?? .idle(symbol: "arrow.counterclockwise"),
            status: preview.map { p in
                let left = p.comparison.itemsToRestore
                if left == 0 { return restored(p) ? "Restored · matches this Mac" : "This Mac already matches" }
                if restored(p) { return "Restored · \(left) item\(left == 1 ? "" : "s") left as \(left == 1 ? "it is" : "they are")" }
                return "\(left) item\(left == 1 ? "" : "s") would change"
            } ?? (latest == nil ? "Preview a backup" : "\(model.foundBackups.count) backup\(model.foundBackups.count == 1 ? "" : "s") found"),
            detail: preview.map { "Compared with \($0.fileName)" }
                ?? latest.map { "Latest: \($0.deviceName), \($0.created.formatted(.relative(presentation: .named))). Or drop a backup file here." }
                ?? "Choose a backup file, or drop one here, to see what restoring it would change.",
            footer: { FolderRow(caption: "Looks in") },
            dropHint: "Drop a backup file to preview it",
            onDrop: busy ? nil : { model.handleRestoreDrop($0) }
        ) {
            HStack(spacing: 8) {
                if preview != nil {
                    Button {
                        model.showingRestorePreview = true
                    } label: {
                        Label("View Changes", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else if let latest {
                    Button {
                        model.previewRestore(latest.url)
                    } label: {
                        Label("Preview Latest", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(busy)
                    .help("Compare \(latest.fileName) with this Mac")
                } else {
                    Button {
                        model.previewRestore()
                    } label: {
                        Label("Choose Backup…", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(busy)
                }
                if preview != nil || latest != nil {
                    Button {
                        model.previewRestore()
                    } label: {
                        Image(systemName: "doc.badge.ellipsis")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .help("Choose another backup file")
                }
            }
        } menu: {
            Button("Choose Backup File…") { model.previewRestore() }
                .disabled(busy)
            if !model.foundBackups.isEmpty {
                Menu("Recent Backups") {
                    ForEach(model.foundBackups.prefix(10)) { file in
                        Button("\(file.deviceName) · \(file.created.formatted(date: .abbreviated, time: .shortened))") {
                            model.previewRestore(file.url)
                        }
                        .disabled(busy)
                    }
                }
            }
            if let preview {
                if let url = model.foundBackups.first(where: { $0.fileName == preview.fileName })?.url {
                    Button("Show Backup in Finder") { model.showInFinder(url) }
                }
                Button("Clear Preview") { model.restorePreview = nil }
            }
            Divider()
            Button("Open Backup Folder") { model.showBackupFolder() }
            Button("Refresh Backup List") { model.refreshFoundBackups() }
                .disabled(!model.findBackupsAutomatically)
            if model.restorePreview != nil {
                Divider()
                Button("Restore This Backup…") { model.showingRestorePreview = true }
            }
        }
    }
}

/// The backup folder's path; click to open it in Finder.
private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let caption: String

    var body: some View {
        Button {
            model.showBackupFolder()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text("\(caption) \(model.isDefaultBackupFolder ? "Cairn's backup folder" : model.backupFolder.lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(BackupFolder.displayPath(model.backupFolder)), click to open in Finder")
    }
}

private struct SyncCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        let others = sync.machines.filter { !$0.isThisMac && $0.syncing }.count
        DashboardCard(
            title: "Sync",
            tint: .purple,
            ring: !sync.isOn ? .disabled(symbol: "arrow.triangle.2.circlepath")
                : sync.pendingCount > 0 ? .idle(symbol: "arrow.down")
                : .progress(1, symbol: "checkmark", label: nil),
            status: !sync.isOn ? "Off"
                : sync.isSyncing ? "Syncing…"
                : sync.pendingCount > 0 ? "\(sync.pendingCount) change\(sync.pendingCount == 1 ? "" : "s") from your other Macs"
                : sync.lastSync == nil ? "Not synced yet" : "In sync",
            detail: !sync.isOn ? "Keep your Macs' setups in step through your backup folder or NAS."
                : others == 0 ? "No other Macs syncing yet. Turn on sync on another Mac using this folder."
                : "With \(others) other Mac\(others == 1 ? "" : "s")\(sync.lastSync.map { ", synced \($0.formatted(.relative(presentation: .named)))" } ?? "").",
            footer: {
                Label(sync.isOn ? "\(sync.config.preset.title) preset" : "Through the backup folder",
                      systemImage: sync.isOn ? "slider.horizontal.3" : "externaldrive.connected.to.line.below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        ) {
            HStack(spacing: 8) {
                if !sync.isOn {
                    Button {
                        model.selection = .sync
                    } label: {
                        Text("Set Up Sync…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                } else if let plan = sync.plan, !plan.incoming.isEmpty {
                    Button {
                        model.reviewIncoming(plan.incoming)
                    } label: {
                        Label("Review Changes", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                } else {
                    Button {
                        model.syncNow()
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(sync.isSyncing || model.isScanning)
                }
            }
        } menu: {
            Button("Open Sync") { model.selection = .sync }
            if sync.isOn { Button("Turn Off Sync on This Mac") { sync.turnOff() } }
        }
    }
}

// MARK: - Card building blocks

enum RingState {
    case idle(symbol: String)
    case progress(Double, symbol: String?, label: String?)
    case disabled(symbol: String)
}

private struct DashboardCard<Actions: View, MenuItems: View, Footer: View>: View {
    let title: String
    let tint: Color
    let ring: RingState
    let status: String
    let detail: String
    let footer: Footer
    /// Shown over the card while something droppable hovers over it.
    let dropHint: String?
    /// Receives dropped files and folders; nil means the card takes no drops.
    let onDrop: (([URL]) -> Bool)?
    let actions: Actions
    let menu: MenuItems
    // Plain State, not @State: the Command Line Tools lack SwiftUI's macro plugin.
    private let dropTarget = State(initialValue: false)
    private var isDropTarget: Bool { dropTarget.wrappedValue }

    init(
        title: String, tint: Color, ring: RingState, status: String, detail: String,
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        dropHint: String? = nil, onDrop: (([URL]) -> Bool)? = nil,
        @ViewBuilder actions: () -> Actions, @ViewBuilder menu: () -> MenuItems
    ) {
        self.title = title
        self.tint = tint
        self.ring = ring
        self.status = status
        self.detail = detail
        self.footer = footer()
        self.dropHint = dropHint
        self.onDrop = onDrop
        self.actions = actions()
        self.menu = menu()
    }

    var body: some View {
        VStack(spacing: 14) {
            StatusRing(state: ring, tint: tint)
                .frame(width: 96, height: 96)
                .padding(.top, 6)

            VStack(spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(height: 44, alignment: .top)
            }

            actions
                .controlSize(.large)

            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(CardBackground(tint: tint))
        .overlay {
            if isDropTarget {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.12))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                    Label(dropHint ?? "Drop here", systemImage: "tray.and.arrow.down.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let onDrop else { return false }
            return onDrop(urls.filter(\.isFileURL))
        } isTargeted: { targeted in
            dropTarget.wrappedValue = targeted && onDrop != nil
        }
        .overlay(alignment: .topTrailing) {
            if MenuItems.self != EmptyView.self {
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(10)
                .help("More \(title.lowercased()) options")
            }
        }
    }
}

/// A circular status ring: a determinate arc, an idle track, or a dashed "not yet" ring.
struct StatusRing: View {
    let state: RingState
    let tint: Color

    var body: some View {
        ZStack {
            switch state {
            case .idle(let symbol):
                Circle().stroke(tint.opacity(0.18), lineWidth: 9)
                center(symbol: symbol, label: nil, color: tint)
            case .progress(let value, let symbol, let label):
                Circle().stroke(tint.opacity(0.18), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: value)
                center(symbol: symbol, label: label, color: tint)
            case .disabled(let symbol):
                Circle().stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 3, dash: [5, 6]))
                center(symbol: symbol, label: nil, color: .secondary)
            }
        }
        .padding(5)
    }

    @ViewBuilder
    private func center(symbol: String?, label: String?, color: Color) -> some View {
        if let label {
            Text(label)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

struct CardBackground: View {
    var tint: Color = .clear

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

private struct Footnote: View {
    var body: some View {
        Label("Scanning and backing up are read-only. Cairn never changes your Mac without showing you exactly what will change first.",
              systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Restore preview sheet

struct RestorePreviewSheet: View {
    @Environment(AppModel.self) private var model
    let preview: RestorePreview

    var body: some View {
        let c = preview.comparison
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Before: how much already matches. After: how many steps checked out
                // (the comparison is from before the restore, so it would be stale).
                if case .running = model.restore.phase {
                    // Progress shows once, as the bar under the big icon (and in the menu bar).
                    Image(nsImage: CairnIcon.image(size: 128) ?? NSImage())
                        .resizable()
                        .frame(width: 60, height: 60)
                        .frame(width: 64, height: 64)
                } else if case .finished(let o) = model.restore.phase {
                    StatusRing(state: .progress(1, symbol: o.problems == 0 ? "checkmark" : "exclamationmark", label: nil),
                               tint: o.problems == 0 ? .green : .orange)
                        .frame(width: 64, height: 64)
                } else {
                    StatusRing(state: .progress(c.matchFraction, symbol: nil,
                                                label: "\(Int((c.matchFraction * 100).rounded()))%"), tint: .blue)
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 3) {
                    let finished: Bool = { if case .finished = model.restore.phase { return true } else { return false } }()
                    let running: Bool = { if case .running = model.restore.phase { return true } else { return false } }()
                    Text(finished ? "Restore finished" : running ? "Restoring…" : "Restore preview").font(.title2.weight(.semibold))
                    Text("\(preview.fileName) · from \(preview.backup.device.name)")
                        .foregroundStyle(.secondary)
                    Text(finished ? "Here's what changed, what Cairn checked, and what's left for you."
                         : running ? "Big downloads can take a while. You can keep using your Mac."
                                   : "\(c.matchingCount) of \(c.backupItemCount) items already match this Mac. Nothing has been changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            switch model.restore.phase {
            case .finished(let outcome):
                RestoreResults(outcome: outcome, log: model.restore.log)
            case .running:
                RestoreProgressPanel()
            default:
                diffList(c)
            }

            Divider()
            RestoreFooter(preview: preview)
                .padding(14)
        }
        .frame(width: 640, height: 560)
        .overlay {
            switch model.restore.phase {
            case .unlocking, .skipWarning:
                ZStack {
                    Rectangle().fill(.black.opacity(0.25)).ignoresSafeArea()
                    VaultUnlockPanel(preview: preview)
                }
                .transition(.opacity)
            default:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.restore.isUnlockShowing)
        .interactiveDismissDisabled(model.restore.isRunning)
    }

    @ViewBuilder
    private func diffList(_ c: BackupComparison) -> some View {
        if c.diff.isEmpty {
            ContentUnavailableView("Nothing to restore", systemImage: "checkmark.circle",
                                   description: Text("This Mac already matches the backup."))
        } else {
            let installs = c.diff.sections.flatMap { sec in sec.added.map { (Self.title(for: sec.name), $0) } }
            let changes = c.diff.sections.flatMap { sec in sec.changed.map { (Self.title(for: sec.name), $0) } }
            let onlyHere = c.diff.sections.flatMap { sec in sec.removed.map { (Self.title(for: sec.name), $0) } }
            List {
                if !installs.isEmpty {
                    Section("Would install (\(installs.count))") {
                        ForEach(installs, id: \.1) { kind, item in
                            row(symbol: "plus.circle.fill", color: .green,
                                text: item.hasPrefix("vault://") ? SecretReader.title(of: item) : item, note: kind)
                        }
                    }
                }
                if !changes.isEmpty {
                    Section("Would change (\(changes.count))") {
                        ForEach(changes, id: \.1.id) { kind, change in
                            row(symbol: "arrow.triangle.2.circlepath.circle.fill", color: .orange, text: change.id,
                                note: "\(change.from) → \(change.to)")
                        }
                    }
                }
                if !onlyHere.isEmpty {
                    Section {
                        DisclosureGroup("Only on this Mac (\(onlyHere.count)): restore leaves these alone") {
                            ForEach(onlyHere, id: \.1) { kind, item in
                                row(symbol: "minus.circle", color: .secondary, text: item, note: kind)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(symbol: String, color: Color, text: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).lineLimit(1)
            Spacer(minLength: 12)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private static func title(for section: String) -> String {
        switch section {
        case "packages": return "Packages"
        case "apps": return "App Store apps"
        case "settings": return "Settings"
        case "layout.dock": return "Dock"
        case "layout.displays": return "Displays"
        case "shares": return "Network shares"
        case "layout.wallpaper": return "Wallpaper"
        case "sensitive": return "Sensitive"
        default: return section
        }
    }
}

/// Restore button, confirmation, progress, and the vault password when needed.
private struct RestoreFooter: View {
    @Environment(AppModel.self) private var model
    let preview: RestorePreview

    /// The user chose to restore without the vault password.
    private var skipsSecrets: Bool { model.restore.skipSecrets }

    var body: some View {
        @Bindable var run = model.restore
        let empty = preview.comparison.diff.isEmpty
        HStack(spacing: 10) {
            switch run.phase {
            case .running:
                ProgressView().controlSize(.small)
                Text("Restoring… you can keep using your Mac.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            case .finished(let o):
                Label(o.problems == 0 ? "Restore finished. \(o.verified) items checked."
                                      : "Restore finished with \(o.problems) problem\(o.problems == 1 ? "" : "s").",
                      systemImage: o.problems == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(o.problems == 0 ? .green : .orange)
                Spacer()
                Button("Done") { model.showingRestorePreview = false; run.reset() }
                    .keyboardShortcut(.defaultAction)
            default:
                let secrets = run.secretSummary(preview)
                if run.unlockedKey != nil {
                    Label("Secrets unlocked", systemImage: "lock.open.fill")
                        .font(.caption).foregroundStyle(.green)
                } else if run.needsVault(preview, model: model) {
                    Label("\(secrets.count) encrypted secret\(secrets.count == 1 ? "" : "s")", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(secrets.text + ". Cairn asks for the vault password when you restore.")
                } else if !preview.logoutSettings.isEmpty {
                    Label("\(preview.logoutSettings.count) settings need a log out",
                          systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(preview.logoutSettings.joined(separator: "\n"))
                }
                Spacer()
                Button("Cancel") { model.showingRestorePreview = false }
                    .keyboardShortcut(.cancelAction)
                Button("Restore…") { run.begin(preview, model: model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(empty)
            }
        }
        .confirmationDialog("Restore this backup to this Mac?",
                            isPresented: Binding(get: { if case .confirming = run.phase { return true } else { return false } },
                                                 set: { if !$0, case .confirming = run.phase { run.phase = .idle } })) {
            Button(skipsSecrets ? "Restore Without Secrets" : "Restore") { run.start(preview, model: model) }
            Button("Cancel", role: .cancel) { run.phase = .idle }
        } message: {
            Text((skipsSecrets ? "No vault password was entered, so this backup's encrypted secrets will be skipped. " : "")
                 + "Cairn installs missing packages, writes settings, secrets, the Dock, and wallpaper, and restarts the Dock and Finder. App Store apps and anything that needs your Mac's password are listed for you to finish by hand. It never removes anything.")
        }
    }
}

/// What a finished restore did, what it checked, and what's left by hand.
private struct RestoreResults: View {
    let outcome: RestoreRun.Outcome
    let log: [RestoreRun.LogLine]

    var body: some View {
        let problems = outcome.checks.filter { $0.status == .mismatch || $0.status == .failed }
        let verified = outcome.checks.filter { $0.status == .verified }
        let skipped = outcome.checks.filter { $0.status == .skipped }
        let r = outcome.report
        List {
            Section {
                RestoreFinishedNotice(outcome: outcome)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
            if !r.needsLogout.isEmpty {
                Section {
                    Label("Log out and back in to finish: \(r.needsLogout.count) setting\(r.needsLogout.count == 1 ? "" : "s") take effect only after that.",
                          systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.orange)
                }
            }
            if !problems.isEmpty {
                Section("Problems (\(problems.count))") {
                    ForEach(problems, id: \.id) { line($0, symbol: "xmark.circle.fill", color: .red) }
                }
            }
            if !r.manualSteps.isEmpty {
                Section("Still to do by hand (\(r.manualSteps.count))") {
                    ForEach(Array(r.manualSteps.enumerated()), id: \.offset) { _, m in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "hand.point.right.fill").foregroundStyle(.blue)
                            Text(m.text)
                            Spacer(minLength: 8)
                            Text(m.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !verified.isEmpty {
                Section {
                    DisclosureGroup("Restored and checked (\(verified.count))") {
                        ForEach(verified, id: \.id) { line($0, symbol: "checkmark.circle.fill", color: .green) }
                    }
                }
            }
            if !skipped.isEmpty {
                Section {
                    DisclosureGroup("Skipped (\(skipped.count))") {
                        ForEach(skipped, id: \.id) { line($0, symbol: "minus.circle", color: .secondary) }
                    }
                }
            }
            if !log.isEmpty {
                Section {
                    DisclosureGroup("Details (\(log.count) lines)") {
                        RestoreLogView(log: log).frame(height: 180)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func line(_ r: RestoreVerification.Result, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(r.id).lineLimit(1)
            Spacer(minLength: 12)
            Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}
