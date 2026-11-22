import AppKit
import CairnCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            Group {
                if model.selection == .home {
                    HomeView()
                } else if let checklist = model.checklist, let category = model.selectedCategory {
                    CategoryDetail(checklist: checklist, category: category)
                } else if model.isScanning {
                    ScanningView()
                } else {
                    ContentUnavailableView("Choose a category", systemImage: "sidebar.left")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search items")
        .toolbar { Toolbar() }
        .sheet(isPresented: $model.showingRestorePreview) {
            if let preview = model.restorePreview {
                RestorePreviewSheet(preview: preview)
                    .environment(model)
            }
        }
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Shared pieces

extension ChecklistCategory {
    var tint: Color {
        switch self {
        case .packages: return .orange
        case .appStore: return .blue
        case .lookAndLayout: return .purple
        case .systemSettings: return Color(nsColor: .systemGray)
        case .appPreferences: return .teal
        case .developer: return .indigo
        case .fonts: return .pink
        case .networkShares: return .cyan
        case .sensitive: return .red
        }
    }
}

/// A System Settings-style rounded tile with a white symbol.
struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// A small rounded count badge, e.g. "12/40".
struct CountBadge: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(prominent ? Color.white : Color.secondary)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            HStack(spacing: 9) {
                SymbolTile(symbol: "house.fill", tint: .teal)
                Text("Home")
            }
            .padding(.vertical, 2)
            .tag(SidebarItem.home)

            Section("Setup") {
                ForEach(ChecklistCategory.allCases) { category in
                    SidebarRow(category: category)
                        .tag(SidebarItem.category(category))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { DeviceHeader() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SelectionSummary() }
    }
}

/// This Mac: its real icon, friendly name, and a small ring while a task runs.
private struct DeviceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: DeviceInfo.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(DeviceInfo.friendlyName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(model.activity?.label ?? DeviceInfo.systemDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let activity = model.activity {
                ActivityRing(activity: activity)
                    .frame(width: 24, height: 24)
                    .help(activity.label)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.activity?.label)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// A small circular progress ring with an icon in the middle. Spins while the
/// task has no measurable progress.
struct ActivityRing: View {
    let activity: AppModel.Activity

    var body: some View {
        ZStack {
            Circle().stroke(activity.tint.opacity(0.2), lineWidth: 3)
            if let fraction = activity.fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(activity.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
            } else {
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(activity.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 360))
                }
            }
            Image(systemName: activity.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(activity.tint)
        }
    }
}

/// Facts about this Mac for display (UI only; the manifest keeps its own device record).
enum DeviceInfo {
    /// The name from System Settings > General > Sharing, e.g. "Aidan's MacBook Pro".
    static let friendlyName = Host.current().localizedName ?? "This Mac"

    /// The system's own picture of this Mac model.
    static let icon: NSImage = NSImage(named: NSImage.computerName) ?? NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")

    static let systemDescription: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let category: ChecklistCategory

    var body: some View {
        HStack(spacing: 9) {
            SymbolTile(symbol: category.symbol, tint: category.tint)
            Text(category.title)
            Spacer()
            if let checklist = model.checklist {
                if checklist.isLocked(category) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if category.isScanned || checklist.count(in: category).total > 0 {
                    let c = checklist.count(in: category, matching: model.query)
                    CountBadge(text: c.checked == c.total ? "\(c.total)" : "\(c.checked)/\(c.total)")
                } else {
                    Text("Soon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SelectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let checklist = model.checklist {
            let total = max(checklist.items.count, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Selected for backup").font(.caption.weight(.medium))
                    Spacer()
                    Text("\(checklist.checkedCount) of \(checklist.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(checklist.checkedCount), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(.teal)
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(12)
        }
    }
}

// MARK: - Detail

private struct CategoryDetail: View {
    @Environment(AppModel.self) private var model
    let checklist: Checklist
    let category: ChecklistCategory

    var body: some View {
        let groups = checklist.groups(in: category, matching: model.query)
        let locked = checklist.isLocked(category)
        VStack(alignment: .leading, spacing: 0) {
            CategoryHeader(checklist: checklist, category: category)
            Divider()
            if locked {
                LockedNotice()
                Spacer()
            } else if groups.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groups, id: \.name) { group in
                        GroupSection(key: "\(category.rawValue)/\(group.name)", name: group.name, items: group.items,
                                     category: category,
                                     expandedByDefault: groups.count <= 4 || !model.query.isEmpty)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else if !category.isScanned {
            ContentUnavailableView {
                Label { Text("Coming in a later milestone") } icon: {
                    SymbolTile(symbol: category.symbol, tint: category.tint, size: 56)
                }
            } description: {
                Text("Cairn doesn't scan \(category.title.lowercased()) yet.")
            }
        } else {
            ContentUnavailableView("Nothing found", systemImage: category.symbol,
                                   description: Text("The scan found no \(category.title.lowercased()) items on this Mac."))
        }
    }
}

private struct CategoryHeader: View {
    @Environment(AppModel.self) private var model
    let checklist: Checklist
    let category: ChecklistCategory

    var body: some View {
        let count = checklist.count(in: category, matching: model.query)
        let state = checklist.state(of: category, matching: model.query)
        let locked = checklist.isLocked(category)
        HStack(spacing: 14) {
            SymbolTile(symbol: category.symbol, tint: category.tint, size: 44)
                .shadow(color: category.tint.opacity(0.35), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(category.title).font(.title2.weight(.semibold))
                Text(subtitle(count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if count.total > 0 && !locked {
                Gauge(value: Double(count.checked), in: 0...Double(count.total)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int((Double(count.checked) / Double(count.total) * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(category.tint)
                .scaleEffect(0.8)

                Button {
                    model.toggleAll(in: category)
                } label: {
                    Label(state == .on ? "Deselect All" : "Select All", systemImage: state.symbol)
                }
                .controlSize(.large)
                .help(model.query.isEmpty ? "Applies to every item in this category" : "Applies to the items matching your search")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            LinearGradient(colors: [category.tint.opacity(0.12), category.tint.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func subtitle(_ count: (checked: Int, total: Int)) -> String {
        if checklist.isLocked(category) { return "Locked until you set a password" }
        if count.total == 0 && !category.isScanned { return "Not scanned yet" }
        return model.query.isEmpty
            ? "\(count.checked) of \(count.total) selected"
            : "\(count.checked) of \(count.total) matching items selected"
    }
}

private struct LockedNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SymbolTile(symbol: "lock.fill", tint: .orange, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sensitive items are encrypted").font(.headline)
                Text("Wi-Fi networks, VPN profiles, SSH keys, and API tokens are only ever stored encrypted with your password. Setting a password arrives in Milestone 4.")
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Set Password…") {}
                    .disabled(true)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(22)
    }
}

private struct GroupSection: View {
    @Environment(AppModel.self) private var model
    let key: String
    let name: String
    let items: [ChecklistItem]
    let category: ChecklistCategory
    let expandedByDefault: Bool

    var body: some View {
        let isExpanded = Binding(
            get: { model.expandedGroups[key] ?? expandedByDefault },
            set: { model.expandedGroups[key] = $0 })
        let checked = items.filter(\.isChecked).count
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(items) { item in
                ItemRow(item: item, category: category)
            }
        } label: {
            HStack {
                Text(name).font(.headline)
                Spacer()
                CountBadge(text: checked == items.count ? "\(items.count)" : "\(checked)/\(items.count)")
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ChecklistItem
    let category: ChecklistCategory

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { item.isChecked }, set: { model.setChecked(item.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            ItemIcon(item: item, category: category)

            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(item.isChecked ? .primary : .secondary)

            Spacer(minLength: 12)

            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.7)))
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.setChecked(item.id, !item.isChecked) }
    }
}

/// The real app icon for App Store apps that are installed in /Applications,
/// otherwise a small symbol for the item's kind.
private struct ItemIcon: View {
    let item: ChecklistItem
    let category: ChecklistCategory

    var body: some View {
        if let icon = AppIcons.icon(for: item, in: category) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(category.tint)
                .frame(width: 18, height: 18)
        }
    }

    private var symbol: String {
        switch item.group {
        case "Formulae": return "terminal"
        case "Casks": return "macwindow"
        case "Taps": return "spigot"
        default: break
        }
        if item.id == "layout:dock" { return "dock.rectangle" }
        if item.id == "layout:displays" { return "display.2" }
        return category == .appStore ? "app" : "slider.horizontal.below.rectangle"
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for item: ChecklistItem, in category: ChecklistCategory) -> NSImage? {
        guard category == .appStore else { return nil }
        if let cached = cache[item.title] { return cached }
        let path = "/Applications/\(item.title).app"
        let image = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
        cache[item.title] = image
        return image
    }
}

private struct ScanningView: View {
    var body: some View {
        VStack(spacing: 14) {
            CairnIconView()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            Text("Scanning this Mac…").font(.title3.weight(.medium))
            Text("Read-only. Nothing on your Mac is changed.")
                .foregroundStyle(.secondary)
            ProgressView().controlSize(.small).padding(.top, 4)
        }
    }
}

// MARK: - Toolbar and status

private struct Toolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.scan()
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .help("Scan this Mac again (read-only)")
            .disabled(model.isScanning)

            Menu {
                ForEach(ChecklistPreset.allCases) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        Text(preset.title)
                        Text(preset.summary)
                    }
                }
            } label: {
                Label("Preset", systemImage: "wand.and.stars")
            }
            .help("Apply a preset selection")
            .disabled(model.checklist == nil)

            Button {
                model.backUp()
            } label: {
                Label("Back Up", systemImage: "arrow.down.doc")
            }
            .help("Save the checked items as a backup in \(BackupFolder.displayPath(model.backupFolder))")
            .disabled(model.checklist == nil)
        }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
            } else if let lastScan = model.lastScan {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Scanned at \(lastScan.formatted(date: .omitted, time: .shortened))")
            }
            if !model.warnings.isEmpty {
                Label("\(model.warnings.count) warning\(model.warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(model.warnings.joined(separator: "\n"))
            }
            Spacer()
            if let status = model.statusMessage {
                Text(status)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension CheckState {
    var symbol: String {
        switch self {
        case .on: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .off: return "square"
        }
    }
}
