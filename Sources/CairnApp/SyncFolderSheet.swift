import AppKit
import CairnCore
import SwiftUI

/// Picks where Macs sync in folder mode: the backup folder, a NAS share that's
/// connected, a share to connect, or any folder. Every Mac points at the same one.
struct SyncFolderSheet: View {
    @Environment(AppModel.self) private var model
    private let address = State(initialValue: "")
    private let shares = State<[MountedShare]>(initialValue: [])

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 30))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Where should your Macs sync?").font(.title2.weight(.semibold))
                    Text("Pick the same folder on every Mac. A NAS share works even when the Macs are never on at the same time. Each Mac writes only its own files there.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FolderSection(title: "Your backup folder") {
                let backup = model.backupFolder
                FolderRow(icon: "folder.fill", title: BackupFolder.displayPath(backup),
                          detail: NetworkShareMounter.share(containing: backup).map { "On \($0.address)" } ?? "Backups and sync in one place",
                          chosen: sync.folder == nil) {
                    Button(sync.folder == nil ? "In Use" : "Use") { sync.setFolder(nil); close() }
                        .disabled(sync.folder == nil && sync.pendingTurnOn == nil)
                }
            }

            if !shares.wrappedValue.isEmpty {
                FolderSection(title: "Connected NAS shares") {
                    ForEach(shares.wrappedValue) { share in
                        FolderRow(icon: "externaldrive.connected.to.line.below", title: share.name, detail: share.address,
                                  chosen: sync.folder.map { $0.path == share.path.path || $0.path.hasPrefix(share.path.path + "/") } ?? false) {
                            Button("Choose Folder…") { pick(in: share.path) }
                        }
                    }
                }
            }

            FolderSection(title: "Connect to a NAS share") {
                HStack(spacing: 8) {
                    Image(systemName: "network").foregroundStyle(.secondary).frame(width: 22)
                    TextField("smb://nas.local/Backups", text: address.projectedValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(connect)
                    if sync.connecting != nil {
                        ProgressView().controlSize(.small)
                    }
                    Button("Connect") { connect() }
                        .disabled(SyncFolder.withoutPassword(address.wrappedValue) == nil || sync.connecting != nil)
                }
                .padding(.vertical, 4)
                Text("macOS asks for the NAS's name and password if it needs them, and keeps them in your Keychain. Then choose a folder on the share.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    pick(in: sync.folder?.url ?? FileManager.default.homeDirectoryForCurrentUser)
                } label: {
                    Label("Choose Another Folder…", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button("Cancel") {
                    sync.pendingTurnOn = nil
                    close()
                }
                .keyboardShortcut(.cancelAction)
            }

            if let error = sync.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            shares.wrappedValue = NetworkShareMounter.mounted()
            address.wrappedValue = sync.folder?.share ?? ""
        }
    }

    private func close() { model.sync.showingFolderSetup = false }

    private func connect() {
        let text = address.wrappedValue
        guard SyncFolder.withoutPassword(text) != nil else { return }
        model.sync.connect(text) { mountPoint in
            shares.wrappedValue = NetworkShareMounter.mounted()
            pick(in: mountPoint)
        }
    }

    /// Asks for a folder, starting in `start`, and uses it.
    private func pick(in start: URL) {
        let panel = NSOpenPanel()
        panel.title = "Choose the Sync Folder"
        panel.message = "Choose the folder your Macs sync through. Pick the same one on each Mac."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = start
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sync = model.sync
        if url.standardizedFileURL == model.backupFolder.standardizedFileURL {
            sync.setFolder(nil)
        } else {
            sync.setFolder(SyncFolder(path: url.standardizedFileURL.path,
                                      share: NetworkShareMounter.share(containing: url)?.address))
        }
        close()
    }
}

private struct FolderSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 4) { content }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
        }
    }
}

private struct FolderRow<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    let chosen: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(chosen ? Color.purple : Color.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if chosen {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple).font(.caption)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            action
        }
        .padding(.vertical, 3)
    }
}
