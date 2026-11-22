import CairnCore
import SwiftUI

/// Create the vault, unlock it, or show the recovery key once.
struct VaultSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var flow = model.vault
        VStack(alignment: .leading, spacing: 14) {
            switch flow.step {
            case .create: createForm(flow)
            case .unlock: unlockForm(flow)
            case .recovery(let key): recovery(key, flow)
            case nil: EmptyView()
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(flow.isWorking)
    }

    private func header(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SymbolTile(symbol: "lock.fill", tint: .orange, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func createForm(_ flow: VaultFlow) -> some View {
        @Bindable var flow = flow
        header("Set a Vault Password",
               "Sensitive items are encrypted with this password before they're saved. Every Mac that backs up to \(BackupFolder.displayPath(model.backupFolder)) uses the same one.")
        SecureField("Password (at least 8 characters)", text: $flow.password)
        SecureField("Repeat password", text: $flow.confirm)
            .onSubmit { flow.create(model) }
        footer(flow, action: "Create Vault", enabled: flow.password.count >= 8 && !flow.confirm.isEmpty) { flow.create(model) }
    }

    @ViewBuilder
    private func unlockForm(_ flow: VaultFlow) -> some View {
        @Bindable var flow = flow
        header("Unlock Sensitive Items",
               flow.useRecoveryKey ? "Enter the recovery key you saved when the vault was created."
                                   : "Enter the vault password for \(BackupFolder.displayPath(model.backupFolder)).")
        if flow.useRecoveryKey {
            TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $flow.password)
                .font(.body.monospaced())
                .onSubmit { flow.unlock(model) }
        } else {
            SecureField("Password", text: $flow.password)
                .onSubmit { flow.unlock(model) }
        }
        Toggle("Use my recovery key instead", isOn: $flow.useRecoveryKey)
            .toggleStyle(.checkbox)
        footer(flow, action: "Unlock", enabled: !flow.password.isEmpty) { flow.unlock(model) }
    }

    @ViewBuilder
    private func recovery(_ key: String, _ flow: VaultFlow) -> some View {
        @Bindable var flow = flow
        header("Save Your Recovery Key",
               "This is the only way back in if you forget your password. Cairn shows it once and never stores it. Keep it in a password manager or on paper.")
        HStack {
            Text(key)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button("Copy") { flow.copyRecoveryKey() }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        Toggle("I've saved my recovery key", isOn: $flow.savedRecoveryKey)
            .toggleStyle(.checkbox)
        HStack {
            Spacer()
            Button("Done") { flow.close() }
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.savedRecoveryKey)
        }
    }

    private func footer(_ flow: VaultFlow, action: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        HStack {
            if let error = flow.error {
                Text(error).foregroundStyle(.red).font(.callout)
            } else if flow.isWorking {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { flow.close() }
                .keyboardShortcut(.cancelAction)
            Button(action, action: perform)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
        }
        .padding(.top, 4)
    }
}
