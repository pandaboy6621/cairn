import AppKit
import CairnCore
import SwiftUI

/// The Sync page: turn sync on, choose what travels, bring in changes from
/// other Macs, settle conflicts, and see the Macs using this backup folder.
struct SyncView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SyncHeader()
                if sync.isOn {
                    if !sync.requests.isEmpty { SyncRequests() }
                    if let plan = sync.plan, !(plan.incoming.isEmpty && plan.conflicts.isEmpty && plan.removedElsewhere.isEmpty) {
                        SyncChanges(plan: plan)
                    }
                    SyncConnection()
                    SyncChoices()
                } else {
                    SyncTurnOn()
                }
                SyncMachines()
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Header

private struct SyncHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(sync.isOn ? Color.purple : Color.secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: sync.isSyncing || model.isScanning)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync").font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
                if let error = sync.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if sync.isOn {
                Button {
                    model.syncNow()
                } label: {
                    Label(sync.isSyncing || model.isScanning ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
                .disabled(sync.isSyncing || model.isScanning)
                Menu {
                    Button("Turn Off Sync on This Mac") { sync.turnOff() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var subtitle: String {
        let sync = model.sync
        guard sync.isOn else { return "Keep your Macs' setups in step, through your NAS or directly between them." }
        let others = sync.trust.devices.count
        var parts: [String] = []
        if let last = sync.lastSync { parts.append("Synced \(last.formatted(.relative(presentation: .named)))") } else { parts.append("Not synced yet") }
        parts.append(others == 0 ? "no Macs paired yet" : "paired with \(others) Mac\(others == 1 ? "" : "s")")
        parts.append(sync.mode == .folder ? "through the shared folder" : "directly between Macs")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Turning on

private struct SyncTurnOn: View {
    @Environment(AppModel.self) private var model
    private let preset = State(initialValue: SyncPreset.portable)
    private let mode = State(initialValue: SyncMode.folder)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cairn keeps your Macs' setups in step and shows you every change from another Mac before anything is applied. Each Mac is paired first, by accepting a request or typing its ID. Sync never removes anything.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("How your Macs connect").font(.headline)
            ModePicker(selection: mode.projectedValue, folder: BackupFolder.displayPath(model.backupFolder))
            Text("What syncs").font(.headline).padding(.top, 4)
            PresetPicker(selection: preset.projectedValue)
            HStack {
                Spacer()
                Button {
                    model.sync.turnOn(preset.wrappedValue, mode: mode.wrappedValue)
                    model.syncNow()
                } label: {
                    Text("Turn On Sync").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
                .disabled(model.checklist == nil)
            }
            Text("You can change any of this later, including single items in the checklist (right-click an item).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(CardBackground(tint: .purple))
    }
}

/// Two cards: through a NAS or shared folder, or directly between Macs.
private struct ModePicker: View {
    @Binding var selection: SyncMode
    let folder: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(SyncMode.allCases) { mode in
                let on = selection == mode
                Button {
                    selection = mode
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: mode == .folder ? "externaldrive.connected.to.line.below" : "laptopcomputer.and.arrow.down")
                            Text(mode == .folder ? "NAS or shared folder" : "Device to device").font(.headline)
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.purple : Color.secondary)
                        }
                        Text(mode.summary + (mode == .folder ? " Uses \(folder)." : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Color.purple.opacity(0.12) : Color.secondary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Color.purple.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Connection and pairing

/// How this Mac connects, its ID, and pairing by ID.
private struct SyncConnection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection").font(.title3.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                Picker("Macs connect", selection: Binding(get: { sync.mode }, set: { sync.setMode($0) })) {
                    Text("Through a NAS or shared folder").tag(SyncMode.folder)
                    Text("Directly between Macs").tag(SyncMode.direct)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            Text(sync.mode.summary + (sync.mode == .folder ? " Folder: \(BackupFolder.displayPath(model.backupFolder))." : ""))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac's ID").font(.caption).foregroundStyle(.secondary)
                    Text(sync.deviceID?.description ?? "…")
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sync.deviceID?.description ?? "", forType: .string)
                }
                Button("Add Mac by ID…") { sync.showingAddDevice = true }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
            Text("To pair, click Pair next to a Mac below: both Macs show a code, and the other one accepts. If no request arrives there, type each Mac's ID into the other with Add Mac by ID.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Macs in the shared folder asking to sync.
private struct SyncRequests: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.purple)
                Text("Wants to sync").font(.title3.weight(.semibold))
            }
            Text("These Macs turned on sync with this folder. Check the ID matches the one shown in Cairn on that Mac before accepting.")
                .font(.callout).foregroundStyle(.secondary)
            ChangeList {
                ForEach(sync.requests, id: \.deviceID) { info in
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.name)
                            Text(info.deviceID?.description ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ignore") { sync.ignore(info) }
                        Button("Accept") { sync.accept(info) }.buttonStyle(.borderedProminent).tint(.purple)
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(16)
        .background(CardBackground(tint: .purple))
    }
}

/// Three cards: Portable, Everything, Nothing.
private struct PresetPicker: View {
    @Binding var selection: SyncPreset

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(SyncPreset.allCases) { preset in
                let on = selection == preset
                Button {
                    selection = preset
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: icon(preset))
                            Text(preset.title).font(.headline)
                            if preset == .portable { Text("Recommended").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.purple : Color.secondary)
                        }
                        Text(preset.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Color.purple.opacity(0.12) : Color.secondary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Color.purple.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(_ p: SyncPreset) -> String {
        switch p {
        case .portable: return "laptopcomputer.and.arrow.down"
        case .everything: return "square.stack.3d.up.fill"
        case .nothing: return "hand.raised"
        }
    }
}

// MARK: - What syncs

private struct SyncChoices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What syncs").font(.title3.weight(.semibold))
                Spacer()
                Menu("Start Over From…") {
                    ForEach(SyncPreset.allCases) { p in
                        Button("\(p.title)\(p == sync.config.preset ? " (current)" : "")") { sync.apply(p) }
                    }
                }
                .fixedSize()
            }
            Text("Preset: \(sync.config.preset.title). \(sync.config.preset.summary)")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(ChecklistCategory.allCases) { category in
                    CategoryScopeRow(category: category)
                    if category != ChecklistCategory.allCases.last { Divider().padding(.leading, 44) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))

            Label("To choose single items, right-click them in the checklist. Synced items show \(Image(systemName: "arrow.triangle.2.circlepath")).",
                  systemImage: "cursorarrow.click.2")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CategoryScopeRow: View {
    @Environment(AppModel.self) private var model
    let category: ChecklistCategory

    var body: some View {
        let sync = model.sync
        let items = model.checklist?.items(in: category) ?? []
        let synced = items.filter { sync.scope(of: $0) == .synced }.count
        let own = sync.config.categoryScope(category)
        let effective = sync.effectiveScope(category, items: items)
        HStack(spacing: 10) {
            SymbolTile(symbol: category.symbol, tint: category.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                Text(items.isEmpty ? "Nothing scanned here yet" : "\(synced) of \(items.count) synced")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    sync.setCategory(category, nil)
                } label: {
                    Label("Preset (\(presetLabel))", systemImage: own == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(SyncScope.allCases) { scope in
                    Button {
                        sync.setCategory(category, scope)
                    } label: {
                        Label(scope.title, systemImage: own == scope ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: symbol(effective)).foregroundStyle(color(effective))
                    Text(effective?.title ?? "Mixed")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(own == nil ? "Following the \(sync.config.preset.title) preset" : "Chosen for this category")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var presetLabel: String {
        let items = model.checklist?.items(in: category) ?? []
        let scopes = Set(items.map { model.sync.config.preset.scopeForDisplay($0.id, category) })
        if scopes.count > 1 { return "mixed" }
        return (scopes.first ?? model.sync.config.preset.scopeForDisplay("", category)).title.lowercased()
    }

    private func symbol(_ s: SyncScope?) -> String {
        switch s {
        case .synced: return "arrow.triangle.2.circlepath"
        case .thisMac: return "laptopcomputer"
        case .ignored: return "minus.circle"
        case nil: return "circle.lefthalf.filled"
        }
    }

    private func color(_ s: SyncScope?) -> Color {
        switch s {
        case .synced: return .purple
        case .thisMac: return .secondary
        case .ignored: return .secondary
        case nil: return .purple.opacity(0.7)
        }
    }
}

// MARK: - Changes

private struct SyncChanges: View {
    @Environment(AppModel.self) private var model
    let plan: SyncPlan

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 12) {
            if !plan.incoming.isEmpty {
                HStack {
                    Text("From your other Macs").font(.title3.weight(.semibold))
                    Text("\(plan.incoming.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.reviewIncoming(plan.incoming)
                    } label: {
                        Label("Review and Apply…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                ChangeList {
                    ForEach(plan.incoming) { item in
                        ChangeRow(category: item.category, title: item.title,
                                  detail: "\(item.current == nil ? "New" : "Changed") on \(item.entry.device) · \(item.entry.updated.formatted(.relative(presentation: .named)))") {
                            Button("Skip") { sync.skip(item) }
                                .buttonStyle(.borderless)
                                .help("Keep this Mac as it is. Offered again if it changes on another Mac.")
                        }
                    }
                }
            }
            if !plan.conflicts.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Changed here and on another Mac").font(.title3.weight(.semibold))
                }
                Text("This Mac's change was newer, so it's the one your other Macs get. Pick the other Mac's instead if you prefer it.")
                    .font(.callout).foregroundStyle(.secondary)
                ChangeList {
                    ForEach(plan.conflicts) { c in
                        ChangeRow(category: c.category, title: c.title,
                                  detail: "Also changed on \(c.theirs.device) \(c.theirs.updated.formatted(.relative(presentation: .named)))") {
                            HStack(spacing: 6) {
                                Button("Keep Mine") { sync.keepMine(c) }
                                Button("Use Theirs…") { model.reviewIncoming([SyncEngine.incoming(from: c)]) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            if !plan.removedElsewhere.isEmpty {
                DisclosureGroup("Removed on another Mac (\(plan.removedElsewhere.count)): left as they are here") {
                    ForEach(plan.removedElsewhere) { r in
                        HStack {
                            Text(r.title)
                            Spacer()
                            Text("on \(r.entry.device)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(CardBackground(tint: .purple))
    }
}

private struct ChangeList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }
}

private struct ChangeRow<Actions: View>: View {
    let category: ChecklistCategory
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.symbol).foregroundStyle(category.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Machines

private struct SyncMachines: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Machines").font(.title3.weight(.semibold))
                Spacer()
                if sync.isOn {
                    Label(sync.peers.isEmpty ? "Looking on your network…" : "\(sync.peers.count) found on your network",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if sync.machines.isEmpty {
                Text("Macs that back up to this folder, or that Cairn finds on your network, show up here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(sync.machines) { m in
                        MachineRow(machine: m)
                        if m != sync.machines.last { Divider().padding(.leading, 52) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
            }
            if !sync.isOn {
                Text("Turn on sync to find other Macs running Cairn on your network and pair with them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MachineRow: View {
    @Environment(AppModel.self) private var model
    let machine: SyncFlow.Machine

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: machine.isThisMac ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 28)
                if machine.online || machine.isThisMac {
                    Circle().fill(.green).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(machine.name).fontWeight(.medium)
                    if machine.isThisMac { Tag(text: "This Mac", color: .teal) }
                    if machine.paired { Tag(text: "Paired", color: .purple) }
                    else if machine.syncing && !machine.isThisMac { Tag(text: "Not paired", color: .orange) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.sync.isOn, !machine.isThisMac, !machine.paired, machine.online, machine.acceptsPairing {
                Button("Pair…") { model.sync.pair(with: machine) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .help("Ask this Mac to sync with this one. Both show a code to compare.")
            }
            if let url = machine.latestBackup, !machine.isThisMac {
                Button("View Setup") { model.previewRestore(url) }
                    .controlSize(.small)
                    .help("Compare its latest backup with this Mac. Nothing changes unless you restore.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            if let url = machine.latestBackup {
                Button("Show Latest Backup in Finder") { model.showInFinder(url) }
            }
            if !machine.isThisMac, machine.paired, let id = machine.deviceID {
                Button("Unpair") { model.sync.unpair(id) }
            }
            if !machine.isThisMac, machine.lastSeen != nil {
                Button("Forget This Mac") { model.sync.forget(machine) }
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let os = machine.osVersion, !os.isEmpty { parts.append("macOS \(os)") }
        if let s = machine.lastSync { parts.append("synced \(s.formatted(.relative(presentation: .named)))") }
        if let b = machine.latestBackupDate { parts.append("backed up \(b.formatted(.relative(presentation: .named)))") }
        if machine.online && !machine.isThisMac { parts.append("on your network now") }
        else if let seen = machine.lastSeen, !machine.isThisMac { parts.append("seen \(seen.formatted(.relative(presentation: .named)))") }
        if let id = machine.deviceID, !machine.isThisMac { parts.append("ID \(id.short)…") }
        return parts.isEmpty ? "No backups in this folder yet" : parts.joined(separator: " · ")
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - Pairing sheets

/// Another Mac asked to pair: compare the code, then accept or decline.
struct PairRequestSheet: View {
    @Environment(AppModel.self) private var model
    let request: PairRequest

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 34)).foregroundStyle(.purple)
            }
            Text("\(request.name) wants to sync with this Mac").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("Check that \(request.name) shows the same code:").foregroundStyle(.secondary)
            Text(request.code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 22).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
            Text("ID \(request.deviceID)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Accepting lets it share its setup with this Mac. You still review every change before it's applied here.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Decline") { model.sync.answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { model.sync.answer(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 440)
    }
}

/// This Mac asked another to pair: show the code while it decides.
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    let pairing: SyncFlow.Pairing

    var body: some View {
        VStack(spacing: 16) {
            switch pairing.stage {
            case .connecting:
                ProgressView().controlSize(.large)
                Text("Connecting to \(pairing.peer)…").font(.title3.weight(.semibold))
            case .waiting(let code):
                Text("Pairing with \(pairing.peer)").font(.title2.weight(.semibold))
                Text("Check that \(pairing.peer) shows this code, then accept there:").foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(pairing.peer)…").foregroundStyle(.secondary)
                }
                Text("No request on \(pairing.peer)? Pair by ID instead.").font(.caption).foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: true)
                Text("Paired with \(pairing.peer)").font(.title2.weight(.semibold))
                Text("Changes from \(pairing.peer) will show on the Sync page for you to review.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                Text("Couldn't pair with \(pairing.peer)").font(.title3.weight(.semibold))
                Text(why).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                switch pairing.stage {
                case .failed, .waiting:
                    Button("Pair by ID…") { model.sync.pairing = nil; model.sync.showingAddDevice = true }
                default: EmptyView()
                }
                Button(pairing.stage == .done ? "Done" : "Close") { model.sync.pairing = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 420)
    }
}

/// Pair by typing the other Mac's ID (and showing this one's to type there).
struct AddDeviceSheet: View {
    @Environment(AppModel.self) private var model
    private let idText = State(initialValue: "")
    private let name = State(initialValue: "")
    private let problem = State<String?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Mac by ID").font(.title2.weight(.semibold))
            Text("On the other Mac, open Cairn > Sync and copy its ID. Then add this Mac's ID there too: both Macs need each other's.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("This Mac's ID").foregroundStyle(.secondary)
                Text(model.sync.deviceID?.description ?? "…").font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.sync.deviceID?.description ?? "", forType: .string)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            TextField("Other Mac's ID (ABCDE-FGHIJ-KLMNO-PQRST)", text: idText.projectedValue)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            TextField("Name (optional, e.g. Studio iMac)", text: name.projectedValue)
                .textFieldStyle(.roundedBorder)
            if let p = problem.wrappedValue {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.sync.showingAddDevice = false }.keyboardShortcut(.cancelAction)
                Button("Add Mac") {
                    if let p = model.sync.add(idText.wrappedValue, name: name.wrappedValue) { problem.wrappedValue = p }
                    else { model.sync.showingAddDevice = false }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(idText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
