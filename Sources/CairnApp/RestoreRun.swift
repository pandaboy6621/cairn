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
        /// The backup has encrypted secrets: the unlock panel is showing.
        case unlocking
        /// Restoring without a password: the "secrets will be skipped" warning.
        case skipWarning
        case confirming
        case running(String)
        case finished(Outcome)
    }

    enum UnlockState: Equatable { case idle, checking, wrong, unlocked }

    /// One row of the running restore's task list.
    struct TaskRow: Identifiable, Equatable {
        enum Status { case pending, active, done }
        let name: String
        var status: Status
        var id: String { name }
    }

    /// One line of the detailed log.
    struct LogLine: Identifiable {
        let id: Int
        let time: Date
        let text: String
        /// A step heading rather than a per-item line.
        let isStep: Bool
    }

    /// What the background restore reports back.
    enum Event: Sendable {
        case planned([String])
        case step(index: Int, total: Int, group: String, title: String)
        case detail(String)
        case checking
    }

    static let checkingTask = "Checking the results"

    var tasks: [TaskRow] = []
    var log: [LogLine] = []
    /// Overall progress, 0...1, while running.
    var fraction: Double = 0
    @ObservationIgnored private var stepIndex = 0
    @ObservationIgnored private var stepTotal = 1

    var phase: Phase = .idle
    /// Typed in the unlock panel when the backup has secrets and the vault is locked.
    var vaultPassword = ""
    var unlock: UnlockState = .idle
    /// Bumped on each wrong password, to shake the panel.
    var wrongAttempts = 0
    /// The user chose to restore without the vault password.
    var skipSecrets = false
    /// The vault key for this restore only, once the panel unlocked it.
    private(set) var unlockedKey: VaultKey?
    var error: String?

    var isRunning: Bool { if case .running = phase { return true } else { return false } }
    /// The vault unlock panel (or its skip warning) is on screen.
    var isUnlockShowing: Bool {
        switch phase { case .unlocking, .skipWarning: return true; default: return false }
    }

    func reset() {
        phase = .idle
        vaultPassword = ""
        unlock = .idle
        wrongAttempts = 0
        skipSecrets = false
        unlockedKey = nil
        error = nil
        tasks = []
        log = []
        fraction = 0
    }

    /// The encrypted secrets this backup would restore, e.g. "3 Wi-Fi passwords and 1 SSH key".
    func secretSummary(_ preview: RestorePreview) -> (count: Int, text: String) {
        let saved = VaultStore.secrets(beside: preview.url).secrets.keys
        let items = preview.backup.sensitive.filter { $0.include && saved.contains($0.ref) }
        var counts: [(String, Int)] = []
        for item in items {
            let kind = SecretReader.kind(of: item.type)
            if let i = counts.firstIndex(where: { $0.0 == kind }) { counts[i].1 += 1 } else { counts.append((kind, 1)) }
        }
        let parts = counts.map { "\($0.1) \($0.0)\($0.1 == 1 ? "" : "s")" }
        let text = parts.count <= 1 ? (parts.first ?? "No secrets")
            : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return (items.count, text)
    }

    /// The Restore… button: asks for the vault password first when the backup
    /// has encrypted secrets and no key is at hand (unlocked or remembered).
    func begin(_ preview: RestorePreview, model: AppModel) {
        guard needsVault(preview, model: model) else { phase = .confirming; return }
        let folder = VaultStore.folder(near: preview.url, fallback: model.backupFolder)
        if let envelope = try? VaultStore.read(in: folder),
           let cached = Vault.cachedKey(for: envelope, cache: KeychainVaultKeyCache()) {
            unlockedKey = cached
            phase = .confirming
            return
        }
        unlock = .idle
        phase = .unlocking
    }

    /// The panel's Unlock button. An empty password asks whether to skip secrets.
    func tryUnlock(_ preview: RestorePreview, model: AppModel) {
        guard unlock != .checking, unlock != .unlocked else { return }
        let password = vaultPassword
        guard !password.isEmpty else { phase = .skipWarning; return }
        unlock = .checking
        let folder = VaultStore.folder(near: preview.url, fallback: model.backupFolder)
        Task {
            let key = await Task.detached(priority: .userInitiated) { () -> VaultKey? in
                guard let envelope = try? VaultStore.read(in: folder) else { return nil }
                return try? Vault.unlock(envelope, password: password)
            }.value
            vaultPassword = ""
            guard let key else {
                unlock = .wrong
                wrongAttempts += 1
                return
            }
            unlockedKey = key
            skipSecrets = false
            unlock = .unlocked
            // Let the padlock open before moving on.
            try? await Task.sleep(for: .milliseconds(1100))
            if case .unlocking = phase { phase = .confirming }
        }
    }

    /// Whether this backup brings secrets that need the vault unlocked.
    func needsVault(_ preview: RestorePreview, model: AppModel) -> Bool {
        let saved = VaultStore.secrets(beside: preview.url).secrets.keys
        let wanted = Set(preview.backup.sensitive.filter(\.include).map(\.ref))
        guard saved.contains(where: wanted.contains), unlockedKey == nil else { return false }
        // The app's own unlocked key only helps for its own backup folder's vault.
        let folder = VaultStore.folder(near: preview.url, fallback: model.backupFolder)
        return model.vault.key == nil || folder.standardizedFileURL != model.backupFolder.standardizedFileURL
    }

    func start(_ preview: RestorePreview, model: AppModel) {
        guard !isRunning else { return }
        error = nil
        let url = preview.url, backup = preview.backup
        let fallback = model.backupFolder
        // The app's unlocked key is for its own backup folder's vault; a backup
        // from elsewhere may have a different one.
        let sameFolder = VaultStore.folder(near: url, fallback: fallback).standardizedFileURL == fallback.standardizedFileURL
        let knownKey = skipSecrets ? nil : (unlockedKey ?? (sameFolder ? model.vault.key : nil))
        let skip = skipSecrets
        vaultPassword = ""
        let cairn = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cairn").path
        tasks = []
        log = []
        fraction = 0
        phase = .running("Checking this Mac")
        addLog("Checking this Mac", isStep: true)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                let report = Self.apply(url: url, backup: backup, fallback: fallback, knownKey: knownKey,
                                        skipSecrets: skip, cairn: cairn) { event in
                    Task { @MainActor in self.handle(event) }
                }
                // Let restarted apps settle before checking.
                try? await Task.sleep(for: .seconds(3))
                let after = SetupScanner().scan().manifest
                return Outcome(report: report, checks: RestoreVerification.check(report, after: after))
            }.value
            for i in tasks.indices { tasks[i].status = .done }
            fraction = 1
            addLog("Finished: \(outcome.verified) checked, \(outcome.problems) problem\(outcome.problems == 1 ? "" : "s"), \(outcome.report.manualSteps.count) to do by hand", isStep: true)
            phase = .finished(outcome)
            model.scan() // the Mac changed; refresh the checklist and preview
        }
    }

    private func addLog(_ text: String, isStep: Bool) {
        log.append(LogLine(id: log.count, time: Date(), text: text, isStep: isStep))
    }

    private func handle(_ event: Event) {
        guard isRunning else { return }
        switch event {
        case .planned(let groups):
            tasks = (groups + [Self.checkingTask]).map { TaskRow(name: $0, status: .pending) }
        case .step(let index, let total, let group, let title):
            stepIndex = index
            stepTotal = max(1, total)
            mark(active: group)
            fraction = Double(index) / Double(stepTotal + 1)
            phase = .running(title)
            addLog(title, isStep: true)
        case .detail(let line):
            // "Installing cask vlc (2 of 4)" moves the ring within the step.
            if let (i, n) = Self.count(in: line) {
                fraction = (Double(stepIndex) + Double(i - 1) / Double(n)) / Double(stepTotal + 1)
            }
            phase = .running(line)
            addLog(line, isStep: false)
        case .checking:
            mark(active: Self.checkingTask)
            fraction = Double(stepTotal) / Double(stepTotal + 1)
            phase = .running(Self.checkingTask)
            addLog(Self.checkingTask, isStep: true)
        }
    }

    /// Marks tasks before `name` done and `name` active.
    private func mark(active name: String) {
        guard let at = tasks.firstIndex(where: { $0.name == name }) else { return }
        for i in tasks.indices { tasks[i].status = i < at ? .done : i == at ? .active : .pending }
    }

    /// (3, 6) for a line ending "(3 of 6)".
    nonisolated static func count(in line: String) -> (Int, Int)? {
        guard let open = line.lastIndex(of: "("), line.hasSuffix(")") else { return nil }
        let parts = line[line.index(after: open)..<line.index(before: line.endIndex)].split(separator: " ")
        guard parts.count == 3, parts[1] == "of", let i = Int(parts[0]), let n = Int(parts[2]), n > 0, i >= 1 else { return nil }
        return (i, n)
    }

    /// The task-list row a plan step belongs to (nil for steps that only note something).
    nonisolated static func group(of step: RestorePlan.Step) -> String? {
        switch step {
        case .commandLineTools: return "Command Line Tools"
        case .packages: return "Installing packages"
        case .appStore: return "App Store apps"
        case .setting, .defaultApps: return "Writing settings"
        case .dock, .wallpaper: return "Dock and wallpaper"
        case .wifi, .secrets: return "Restoring secrets"
        case .pending: return nil
        }
    }

    /// A log heading for a plan step.
    nonisolated static func title(of step: RestorePlan.Step) -> String {
        switch step {
        case .commandLineTools: return "Command Line Tools"
        case .packages(let p): return "Installing \(p.count) package\(p.count == 1 ? "" : "s")"
        case .appStore(let a): return "Listing \(a.count) App Store app\(a.count == 1 ? "" : "s") to install by hand"
        case .setting(let item, _): return "Setting \(item.key)"
        case .defaultApps(let h): return "Setting \(h.count) default app\(h.count == 1 ? "" : "s")"
        case .dock: return "Rebuilding the Dock"
        case .wallpaper: return "Setting the wallpaper"
        case .wifi(let n): return "Saving \(n.count) Wi-Fi network\(n.count == 1 ? "" : "s")"
        case .secrets(let s): return "Restoring \(s.count) secret\(s.count == 1 ? "" : "s")"
        case .pending(let category, let id, _): return "Noting \(category) \(id) for later"
        }
    }

    nonisolated static func apply(url: URL, backup: Manifest, fallback: URL, knownKey: VaultKey?, skipSecrets: Bool,
                                  cairn: String, progress: @escaping @Sendable (Event) -> Void) -> RestoreReport {
        let secrets = VaultStore.secrets(beside: url)
        let before = SetupScanner().scan().manifest
        let plan = RestorePlan.make(backup: backup, current: before, manual: MacRestorer.manualStep,
                                    savedSecrets: Set(secrets.secrets.keys),
                                    environment: MacRestorer.detectEnvironment())
        let steps = plan.steps
        var groups: [String] = []
        for g in steps.compactMap(group(of:)) where !groups.contains(g) { groups.append(g) }
        progress(.planned(groups))
        let report = MacRestorer().apply(plan, backup: url.standardized.path, secrets: secrets, unlock: {
            if let knownKey { return knownKey }
            if skipSecrets { throw RestoreRunError.noPassword }
            let envelope = try VaultStore.read(in: VaultStore.folder(near: url, fallback: fallback))
            if let cached = Vault.cachedKey(for: envelope, cache: KeychainVaultKeyCache()) { return cached }
            throw RestoreRunError.noPassword
        }, progress: { progress(.detail($0)) }, stepStarted: { index, total in
            let step = steps[index]
            progress(.step(index: index, total: total, group: group(of: step) ?? "", title: title(of: step)))
        })
        progress(.checking)
        // Dock tiles for apps that aren't installed yet: added once they are.
        if var pending = try? PendingDock.read(), pending.update(after: report) {
            try? pending.write()
            if pending.isEmpty { DockAgent().remove() }
            else if FileManager.default.isExecutableFile(atPath: cairn) { try? DockAgent().install(cairn: cairn) }
        }
        return report
    }
}

enum RestoreRunError: LocalizedError {
    case noPassword
    var errorDescription: String? { "no vault password was entered, so saved secrets were skipped" }
}

#if DEBUG
extension RestoreRun {
    /// For `CAIRN_SNAPSHOT_RESTORE`: shows a restore state with made-up data,
    /// without restoring anything.
    func debugShow(_ state: String) {
        switch state {
        case "unlock": phase = .unlocking
        case "wrong": phase = .unlocking; unlock = .wrong
        case "unlocked": phase = .unlocking; unlock = .unlocked
        case "skip": phase = .skipWarning
        case "running", "finished":
            tasks = [TaskRow(name: "Installing packages", status: .done), TaskRow(name: "Writing settings", status: .active),
                     TaskRow(name: "Dock and wallpaper", status: .pending), TaskRow(name: Self.checkingTask, status: .pending)]
            let lines = [("Checking this Mac", true), ("Installing 2 packages", true), ("Installing formula example (1 of 2)", false),
                         ("Installing cask example-app (2 of 2)", false), ("Setting dock.autohide", true)]
            log = lines.enumerated().map { LogLine(id: $0.offset, time: Date(), text: $0.element.0, isStep: $0.element.1) }
            fraction = 0.45
            phase = .running("Setting dock.autohide")
            if state == "finished" {
                for i in tasks.indices { tasks[i].status = .done }
                var report = RestoreReport()
                report.manualSteps = [.init(category: "app store", text: "sign in to the App Store, then install 1 app")]
                phase = .finished(Outcome(report: report, checks: []))
            }
        default: break
        }
    }
}
#endif
