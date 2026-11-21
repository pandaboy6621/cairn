import CairnCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            Group {
                if let checklist = model.checklist, let category = model.selectedCategory {
                    CategoryDetail(checklist: checklist, category: category)
                } else if model.isScanning {
                    ProgressView("Scanning this Mac…")
                } else {
                    ContentUnavailableView("Choose a category", systemImage: "sidebar.left")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search items")
        .toolbar { Toolbar() }
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedCategory) {
            Section("Categories") {
                ForEach(ChecklistCategory.allCases) { category in
                    SidebarRow(category: category)
                        .tag(category)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let category: ChecklistCategory

    var body: some View {
        HStack {
            Label(category.title, systemImage: category.symbol)
            Spacer()
            if let checklist = model.checklist {
                if checklist.isLocked(category) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Set a password to enable Sensitive items")
                } else if category.isScanned || checklist.count(in: category).total > 0 {
                    let c = checklist.count(in: category, matching: model.query)
                    Text("\(c.checked)/\(c.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
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
                emptyState(locked: locked)
            } else {
                List {
                    ForEach(groups, id: \.name) { group in
                        GroupSection(key: "\(category.rawValue)/\(group.name)", name: group.name, items: group.items,
                                     expandedByDefault: groups.count <= 4 || !model.query.isEmpty)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func emptyState(locked: Bool) -> some View {
        if !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else if !category.isScanned {
            ContentUnavailableView(
                "Not scanned yet",
                systemImage: category.symbol,
                description: Text("\(category.title) scanning comes in a later milestone."))
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
        HStack(spacing: 12) {
            Button {
                model.toggleAll(in: category)
            } label: {
                Image(systemName: state.symbol)
                    .font(.title2)
                    .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(count.total == 0 || checklist.isLocked(category))
            .help(state == .on ? "Uncheck all" : "Check all")

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title).font(.title2.bold())
                Text(model.query.isEmpty
                     ? "\(count.checked) of \(count.total) selected"
                     : "\(count.checked) of \(count.total) matching items selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct LockedNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
            Text("Set a password to enable Sensitive items. Wi-Fi networks, VPN profiles, SSH keys, and API tokens are always encrypted (coming in Milestone 4).")
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(16)
    }
}

private struct GroupSection: View {
    @Environment(AppModel.self) private var model
    let key: String
    let name: String
    let items: [ChecklistItem]
    let expandedByDefault: Bool

    var body: some View {
        let isExpanded = Binding(
            get: { model.expandedGroups[key] ?? expandedByDefault },
            set: { model.expandedGroups[key] = $0 })
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(items) { item in
                ItemRow(item: item)
            }
        } label: {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text("\(items.filter(\.isChecked).count)/\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ChecklistItem

    var body: some View {
        Toggle(isOn: Binding(get: { item.isChecked }, set: { model.setChecked(item.id, $0) })) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 1)
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
                Label("Preset", systemImage: "list.bullet.rectangle")
            }
            .help("Apply a preset selection")
            .disabled(model.checklist == nil)

            Button {
                model.export()
            } label: {
                Label("Export Manifest", systemImage: "square.and.arrow.up")
            }
            .help("Write a manifest with only the checked items")
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
            } else if let checklist = model.checklist {
                Text("\(checklist.checkedCount) of \(checklist.items.count) items selected")
                if let lastScan = model.lastScan {
                    Text("· scanned \(lastScan.formatted(date: .omitted, time: .shortened))")
                }
            }
            if !model.warnings.isEmpty {
                Label("\(model.warnings.count) warning\(model.warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
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
