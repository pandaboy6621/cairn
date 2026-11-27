import CairnCore
import SwiftUI

/// Cairn ▸ Settings (⌘,), also opened from the gear on Home.
struct SettingsView: View {
    var body: some View {
        TabView {
            BackupSettings()
                .tabItem { Label("Backups", systemImage: "externaldrive") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
    }
}

private struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    // Plain State, not @State: the Command Line Tools lack SwiftUI's macro plugin.
    private let dropTarget = State(initialValue: false)
    private var isDropTarget: Bool { dropTarget.wrappedValue }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Backup folder") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundStyle(.teal)
                            Text(BackupFolder.displayPath(model.backupFolder))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(isDropTarget ? 1 : 0.5)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isDropTarget ? Color.teal : .clear, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
                            model.backupFolder = folder
                            return true
                        } isTargeted: { dropTarget.wrappedValue = $0 }
                        .help("Drop a folder here to use it")

                        HStack {
                            Button("Choose…") { model.chooseBackupFolder() }
                            Button("Show in Finder") { model.showBackupFolder() }
                            if !model.isDefaultBackupFolder {
                                Button("Use Default") { model.resetBackupFolder() }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            } footer: {
                Text("Back Up Now saves snapshots here, and Restore looks here for backups. A mounted NAS share works too. The default is Cairn's own folder in Application Support.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Back up automatically", isOn: Binding(
                    get: { model.autoBackup != nil },
                    set: { model.setAutoBackup($0) }))
                Picker("Check every", selection: $model.autoBackupMinutes) {
                    ForEach(Self.intervals, id: \.minutes) { Text($0.title).tag($0.minutes) }
                }
                .disabled(model.autoBackup == nil)
            } footer: {
                Text("Cairn checks at login, on this schedule, and soon after Dock, Finder, keyboard or trackpad settings change. It saves a snapshot only when something changed. If the folder is a NAS share that isn't connected, snapshots wait on this Mac until it is.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Cairn in the menu bar", isOn: $model.showInMenuBar)
                Toggle("Open at login", isOn: Binding(get: { model.loginItem.isOn || model.loginItem.needsApproval },
                                                      set: { model.loginItem.set($0) }))
                if model.loginItem.needsApproval {
                    HStack {
                        Text("macOS needs you to allow Cairn in Login Items.").foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { model.loginItem.openSystemSettings() }
                    }
                    .font(.callout)
                }
                if let error = model.loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text("Back up from the menu bar without opening the window. While it's showing, closing the window keeps Cairn running there. Opened at login, Cairn starts quietly in the menu bar.")
                    .foregroundStyle(.secondary)
            }
            .onAppear { model.loginItem.refresh() }

            Section {
                Toggle("Ask where to save each backup", isOn: $model.askWhereToSave)
                Toggle("Find backups in the backup folder automatically", isOn: $model.findBackupsAutomatically)
            } footer: {
                Text(foundSummary).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    static let intervals: [(minutes: Int, title: String)] = [
        (15, "15 minutes"), (30, "30 minutes"), (60, "Hour"), (180, "3 hours"), (360, "6 hours"), (1440, "Day"),
    ]

    private var foundSummary: String {
        guard model.findBackupsAutomatically else { return "Restore only uses files you choose or drop on it." }
        let n = model.foundBackups.count
        return n == 0 ? "No backups in this folder yet." : "\(n) backup\(n == 1 ? "" : "s") found. The newest is offered on the Restore card."
    }
}

private struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        Form {
            Section {
                LabeledContent("Version", value: Cairn.version)
                HStack {
                    Text(status).foregroundStyle(.secondary)
                    Spacer()
                    Button(updates.menuTitle.replacingOccurrences(of: "…", with: "")) { updates.menuAction() }
                        .disabled(updates.phase == .checking || isInstalling)
                }
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                Toggle("Install updates automatically", isOn: $updates.installsAutomatically)
                    .disabled(!updates.checksAutomatically || !updates.canInstall)
            } footer: {
                Text(updates.canInstall
                     ? "Cairn checks GitHub a minute after it opens and every 6 hours. An update is installed only if it matches its checksum and code signature, never while a restore, scan or backup is running. If no window is open Cairn restarts on its own; otherwise it asks."
                     : "This copy of Cairn isn't in an Applications folder, so it only checks. Move it to Applications to install updates automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var isInstalling: Bool {
        if case .installing = model.updates.phase { return true } else { return false }
    }

    private var status: String {
        switch model.updates.phase {
        case .checking: return "Checking…"
        case .upToDate: return "Cairn is up to date."
        case .available(let u): return "Cairn \(u.version) is available."
        case .installing(let u): return "Installing Cairn \(u.version)…"
        case .ready(let u): return "Cairn \(u.version) is installed. Restart to finish."
        case .failed(let why): return why
        case .idle:
            guard let last = model.updates.lastChecked else { return "Not checked yet." }
            return "Last checked " + last.formatted(.relative(presentation: .named)) + "."
        }
    }
}
