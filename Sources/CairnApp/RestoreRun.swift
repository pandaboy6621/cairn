import AppKit
import CairnCore
import Observation

/// Applies a restore from the preview sheet: the same steps as
/// `cairn restore --apply`, in dependency order, then a rescan to verify.
@MainActor @Observable
final class RestoreRun {
    struct Outcome {
        let report: RestoreReport
        let checks: [RestoreVerification.Result]
        var problems: Int { checks.filter { $0.status == .mismatch || $0.status == .failed }.count }
        var verified: Int { checks.filter { $0.status == .verified }.count }
    }

    enum Phase {
        case idle
        case confirming
        case running(String)
        case finished(Outcome)
    }

    var phase: Phase = .idle
    /// Typed in the sheet when the backup has secrets and the vault is locked.
    var vaultPassword = ""
    var error: String?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    func reset() {
        phase = .idle
        vaultPassword = ""
        error = nil
    }

    /// Whether this backup brings secrets that need the vault unlocked.
    func needsVault(_ preview: RestorePreview, model: AppModel) -> Bool {
        let saved = VaultStore.secrets(beside: preview.url).secrets.keys
        let wanted = Set(preview.backup.sensitive.filter(\.include).map(\.ref))
        return model.vault.key == nil && saved.contains(where: wanted.contains)
    }

    func start(_ preview: RestorePreview, model: AppModel) {
        guard !isRunning else { return }
        error = nil
        let url = preview.url, backup = preview.backup
        let fallback = model.backupFolder
        let knownKey = model.vault.key
        let password = vaultPassword
        vaultPassword = ""
        let cairn = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cairn").path
        phase = .running("Checking this Mac")
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                let report = Self.apply(url: url, backup: backup, fallback: fallback, knownKey: knownKey,
                                        password: password, cairn: cairn) { line in
                    Task { @MainActor in if self.isRunning { self.phase = .running(line) } }
                }
                // Let restarted apps settle before checking.
                try? await Task.sleep(for: .seconds(3))
                let after = SetupScanner().scan().manifest
                return Outcome(report: report, checks: RestoreVerification.check(report, after: after))
            }.value
            phase = .finished(outcome)
            model.scan() // the Mac changed; refresh the checklist and preview
        }
    }

    nonisolated static func apply(url: URL, backup: Manifest, fallback: URL, knownKey: VaultKey?, password: String,
                                  cairn: String, progress: @escaping @Sendable (String) -> Void) -> RestoreReport {
        let secrets = VaultStore.secrets(beside: url)
        let before = SetupScanner().scan().manifest
        let plan = RestorePlan.make(backup: backup, current: before, manual: MacRestorer.manualStep,
                                    savedSecrets: Set(secrets.secrets.keys),
                                    environment: MacRestorer.detectEnvironment())
        let report = MacRestorer().apply(plan, backup: url.standardized.path, secrets: secrets, unlock: {
            if let knownKey { return knownKey }
            let envelope = try VaultStore.read(in: VaultStore.folder(near: url, fallback: fallback))
            if let cached = Vault.cachedKey(for: envelope, cache: KeychainVaultKeyCache()) { return cached }
            guard !password.isEmpty else { throw VaultError.wrongPassword }
            return try Vault.unlock(envelope, password: password)
        }, progress: progress)
        // Dock tiles for apps that aren't installed yet: added once they are.
        if !report.waitingForDock.isEmpty, var pending = try? PendingDock.read() {
            pending.merge(report.waitingForDock)
            try? pending.write()
            if FileManager.default.isExecutableFile(atPath: cairn) { try? DockAgent().install(cairn: cairn) }
        }
        return report
    }
}
