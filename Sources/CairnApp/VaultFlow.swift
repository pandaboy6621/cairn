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
    /// Refs with a secret saved in this device's secrets file.
    var captured: Set<String> = []
    /// Refs to capture once the user unlocks.
    private var pendingCapture: [String]?
    var isCapturing = false
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

    func folderChanged(_ model: AppModel) {
        key = nil
        model.checklist?.setSensitiveUnlocked(exists(in: model.backupFolder))
        if let device = model.checklist?.source.device.name {
            reloadCaptured(folder: model.backupFolder, device: device)
            model.checklist?.checkCaptured(captured)
        }
    }

    func reloadCaptured(folder: URL, device: String) {
        captured = Set(VaultStore.readSecrets(in: folder, device: device).secrets.keys)
    }

    /// Reads the passwords for these Wi-Fi refs (macOS asks for approval for
    /// each one) and saves them encrypted. Unlocks first if needed.
    func captureWiFi(_ refs: [String], model: AppModel) {
        guard !refs.isEmpty, !isCapturing else { return }
        guard let key else {
            pendingCapture = refs
            begin(model)
            return
        }
        guard let device = model.checklist?.source.device.name else { return }
        let folder = model.backupFolder
        isCapturing = true
        model.statusMessage = "Saving \(refs.count) Wi-Fi password\(refs.count == 1 ? "" : "s"). macOS will ask you to approve each one."
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> SecretCapture.Report in
                    let runner = ProcessRunner(policy: .wifiPasswords)
                    let existing = VaultStore.readSecrets(in: folder, device: device)
                    let (file, report) = SecretCapture.capture(refs, into: existing, key: key) { ref in
                        guard let ssid = WiFiPasswords.ssid(ref: ref) else { return nil }
                        return try WiFiPasswords.read(ssid: ssid, using: runner)
                    }
                    try VaultStore.writeSecrets(file, in: folder, device: device)
                    return report
                }
            }.value
            isCapturing = false
            switch result {
            case .failure(let e):
                model.errorMessage = "Couldn't save Wi-Fi passwords: \(e.localizedDescription)"
            case .success(let report):
                reloadCaptured(folder: folder, device: device)
                model.checklist?.checkCaptured(captured)
                model.statusMessage = Self.describe(report)
            }
        }
    }

    static func describe(_ r: SecretCapture.Report) -> String {
        var parts = ["Saved \(r.saved.count) Wi-Fi password\(r.saved.count == 1 ? "" : "s")"]
        if !r.unchanged.isEmpty { parts.append("\(r.unchanged.count) unchanged") }
        if !r.missing.isEmpty { parts.append("\(r.missing.count) with no password in the Keychain") }
        if !r.failed.isEmpty { parts.append("\(r.failed.count) failed") }
        return parts.joined(separator: ", ") + (r.stoppedEarly ? ". Stopped when you cancelled a prompt." : ".")
    }

    func close() {
        if case .recovery = step {} else { pendingCapture = nil }
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
                if let device = model.checklist?.source.device.name {
                    reloadCaptured(folder: model.backupFolder, device: device)
                    model.checklist?.checkCaptured(captured)
                }
                clearFields()
                step = recovery.map { .recovery($0) }
                if let refs = pendingCapture {
                    pendingCapture = nil
                    captureWiFi(refs, model: model)
                }
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
