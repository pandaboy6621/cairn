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
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Mac's setup")
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
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
            detail: detail
        ) {
            Button {
                model.export()
            } label: {
                Label("Back Up Now…", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .disabled(model.checklist == nil || model.isScanning)
        } menu: {
            Button("Choose What to Back Up") { model.selection = .category(.packages) }
            Menu("Apply Preset") {
                ForEach(ChecklistPreset.allCases) { preset in
                    Button(preset.title) { model.apply(preset) }
                }
            }
            Button("Scan Again") { model.scan() }
                .disabled(model.isScanning)
            Divider()
            Button("Automatic Backups (Milestone 3)") {}
                .disabled(true)
        }
    }

    private var ring: RingState {
        if model.isScanning {
            let p = model.scanProgress
            return .progress(p?.fraction ?? 0, symbol: "magnifyingglass", label: nil)
        }
        guard let c = model.checklist else { return .idle(symbol: "externaldrive") }
        let fraction = c.items.isEmpty ? 0 : Double(c.checkedCount) / Double(c.items.count)
        return .progress(fraction, symbol: model.lastBackupDate == nil ? "externaldrive" : "externaldrive.badge.checkmark",
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
        if let date = model.lastBackupDate {
            return "Last backup \(date.formatted(.relative(presentation: .named)))"
        }
        return "No backups yet. Saves a manifest file you can restore from."
    }
}

private struct RestoreCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preview = model.restorePreview
        DashboardCard(
            title: "Restore",
            tint: .blue,
            ring: preview.map { .progress($0.comparison.matchFraction, symbol: nil,
                                          label: "\(Int(($0.comparison.matchFraction * 100).rounded()))%") }
                ?? .idle(symbol: "arrow.counterclockwise"),
            status: preview.map { p in
                p.comparison.itemsToRestore == 0
                    ? "This Mac already matches"
                    : "\(p.comparison.itemsToRestore) item\(p.comparison.itemsToRestore == 1 ? "" : "s") would change"
            } ?? "Preview a backup",
            detail: preview.map { "Compared with \($0.fileName)" }
                ?? "See what restoring a backup would install or change. Nothing is changed."
        ) {
            if preview != nil {
                Button {
                    model.showingRestorePreview = true
                } label: {
                    Label("View Changes", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            } else {
                Button {
                    model.previewRestore()
                } label: {
                    Label("Preview Restore…", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(model.checklist == nil || model.isScanning)
            }
        } menu: {
            Button("Preview Another Backup…") { model.previewRestore() }
                .disabled(model.checklist == nil || model.isScanning)
            if preview != nil {
                Button("Clear Preview") { model.restorePreview = nil }
            }
            Divider()
            Button("Apply Restore (Milestone 5)") {}
                .disabled(true)
        }
    }
}

private struct SyncCard: View {
    var body: some View {
        DashboardCard(
            title: "Sync",
            tint: .purple,
            ring: .disabled(symbol: "arrow.triangle.2.circlepath"),
            status: "Coming later",
            detail: "Keep settings in step across your Macs through your NAS."
        ) {
            Button {} label: {
                Text("Coming Soon").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(true)
        } menu: {
            EmptyView()
        }
    }
}

// MARK: - Card building blocks

enum RingState {
    case idle(symbol: String)
    case progress(Double, symbol: String?, label: String?)
    case disabled(symbol: String)
}

private struct DashboardCard<Actions: View, MenuItems: View>: View {
    let title: String
    let tint: Color
    let ring: RingState
    let status: String
    let detail: String
    @ViewBuilder let actions: Actions
    @ViewBuilder let menu: MenuItems

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
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(CardBackground(tint: tint))
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
                StatusRing(state: .progress(c.matchFraction, symbol: nil,
                                            label: "\(Int((c.matchFraction * 100).rounded()))%"), tint: .blue)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restore preview").font(.title2.weight(.semibold))
                    Text("\(preview.fileName) · from \(preview.backup.device.name)")
                        .foregroundStyle(.secondary)
                    Text("\(c.matchingCount) of \(c.backupItemCount) items already match this Mac. Nothing has been changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

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
                                row(symbol: "plus.circle.fill", color: .green, text: item, note: kind)
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

            Divider()
            HStack {
                Text("Applying a restore arrives in Milestone 5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.showingRestorePreview = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 520)
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
        case "sensitive": return "Sensitive"
        default: return section
        }
    }
}
