import AppKit
import CairnCore
import Observation

/// Setting the vault password, unlocking, and showing the recovery key once.
/// The unlocked key lives only in memory for this run of the app.
@MainActor @Observable
final class VaultFlow {
    enum Step: Equatable {
        case create
        case unlock
        /// Shown once after creating; the key is dropped when the sheet closes.
        case recovery(String)
    }

    var step: Step?
    var key: VaultKey?
    var password = ""
    var confirm = ""
    var useRecoveryKey = false
    var savedRecoveryKey = false
    var isWorking = false
    var error: String?

    var isPresented: Bool {
        get { step != nil }
        set { if !newValue { close() } }
    }

    func exists(in folder: URL) -> Bool { VaultStore.exists(in: folder) }

    /// Opens the right sheet for the backup folder: create or unlock.
    func begin(_ model: AppModel) {
        clearFields()
        step = exists(in: model.backupFolder) ? .unlock : .create
    }

    func create(_ model: AppModel) {
        guard password == confirm else { error = "The passwords don't match."; return }
        let folder = model.backupFolder, password = password
        run(model) {
            let made = try Vault.create(password: password)
            try VaultStore.write(made.envelope, in: folder)
            return (made.key, made.recoveryKey)
        }
    }

    func unlock(_ model: AppModel) {
        let folder = model.backupFolder, secret = password, recovery = useRecoveryKey
        run(model) {
            let envelope = try VaultStore.read(in: folder)
            let key = recovery ? try Vault.unlock(envelope, recoveryKey: secret) : try Vault.unlock(envelope, password: secret)
            return (key, nil)
        }
    }

    func lock(_ model: AppModel) {
        key = nil
        model.checklist?.setSensitiveUnlocked(false)
    }

    func close() {
        step = nil
        clearFields()
    }

    func copyRecoveryKey() {
        guard case .recovery(let text) = step else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// PBKDF2 at 600,000 iterations takes a moment: do it off the main thread.
    private func run(_ model: AppModel, _ work: @escaping @Sendable () throws -> (VaultKey, String?)) {
        isWorking = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            isWorking = false
            switch result {
            case .success(let (key, recovery)):
                self.key = key
                model.checklist?.setSensitiveUnlocked(true)
                clearFields()
                step = recovery.map { .recovery($0) }
            case .failure(let e):
                error = e.localizedDescription
                password = ""
                confirm = ""
            }
        }
    }

    private func clearFields() {
        password = ""
        confirm = ""
        useRecoveryKey = false
        savedRecoveryKey = false
        error = nil
    }
}
