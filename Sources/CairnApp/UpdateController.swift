import AppKit
import CairnCore
import SwiftUI

/// Keeps Cairn up to date from its GitHub Releases: checks a minute after launch and
/// every few hours, and (if allowed) downloads, checks and installs a new version,
/// then restarts into it. Check for Updates… in the Cairn menu and the menu bar icon
/// does the same on demand and always says what it found.
@MainActor @Observable
final class UpdateController {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Updates.Update)
        case installing(Updates.Update)
        /// The new app is in place; a restart finishes the update.
        case ready(Updates.Update)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Self.checkKey); schedule() }
    }
    var installsAutomatically: Bool {
        didSet { defaults.set(installsAutomatically, forKey: Self.installKey) }
    }

    /// True while Cairn is restoring, scanning or backing up: an install waits.
    @ObservationIgnored var isBusy: () -> Bool = { false }

    /// The installed Cairn.app this copy can replace; nil for a build run from the
    /// project, which only checks.
    let app: URL? = AppUpdater.installedApp()
    var canInstall: Bool { app != nil }

    @ObservationIgnored private let updater = AppUpdater()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var working = false

    static let checkKey = "updatesCheckAutomatically"
    static let installKey = "updatesInstallAutomatically"
    static let lastCheckKey = "updatesLastChecked"
    static let interval: TimeInterval = 6 * 60 * 60
    static let firstCheckDelay: TimeInterval = 60

    init() {
        checksAutomatically = defaults.object(forKey: Self.checkKey) as? Bool ?? true
        installsAutomatically = defaults.object(forKey: Self.installKey) as? Bool ?? true
        lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Starts the automatic checks (if they're on).
    func start() { schedule() }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically else { return }
        let due = lastChecked.map { max(Self.firstCheckDelay, Self.interval - Date().timeIntervalSince($0)) } ?? Self.firstCheckDelay
        timer = Timer.scheduledTimer(withTimeInterval: min(due, Self.interval), repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.check(userInitiated: false)
                self?.schedule()
            }
        }
    }

    /// The text for the menu item, which also finishes an installed update.
    var menuTitle: String {
        if case .ready(let u) = phase { return "Restart to Update to \(u.version)" }
        return "Check for Updates…"
    }

    /// Check for Updates… / Restart to Update.
    func menuAction() {
        if case .ready = phase { relaunch(); return }
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        guard !working else { return }
        if case .ready = phase { if userInitiated { offerRestart() }; return }
        working = true
        phase = .checking
        defer { working = false }
        do {
            let found = try await updater.check()
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckKey)
            guard let update = found else {
                phase = .upToDate
                if userInitiated { inform("You're up to date", "Cairn \(Cairn.version) is the newest version.") }
                return
            }
            phase = .available(update)
            if userInitiated {
                offer(update)
            } else if installsAutomatically, canInstall {
                await install(update, restartNow: false)
            } else {
                SyncNotifier.shared.report("Cairn \(update.version) is available", "Choose Check for Updates… in the Cairn menu to install it.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if userInitiated { inform("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// Downloads, checks and installs `update`, waiting while Cairn is busy. Restarts
    /// right away when asked to, or when no window is open (Cairn is only in the menu bar).
    func install(_ update: Updates.Update, restartNow: Bool) async {
        guard let app else { return }
        working = true
        defer { working = false }
        while isBusy() { try? await Task.sleep(for: .seconds(30)) }
        phase = .installing(update)
        do {
            let staged = try await updater.prepare(update, replacing: app)
            while isBusy() { try? await Task.sleep(for: .seconds(30)) }
            try updater.install(staged, over: app)
            phase = .ready(update)
        } catch {
            phase = .failed(error.localizedDescription)
            if restartNow { inform("Couldn't install the update", error.localizedDescription) }
            return
        }
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if restartNow || !windowOpen {
            relaunch()
        } else {
            SyncNotifier.shared.report("Cairn \(update.version) is installed", "Restart Cairn to finish updating.")
            offerRestart()
        }
    }

    /// Opens the new copy and quits this one.
    func relaunch() {
        guard let app else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = NSApp.isActive
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    self.inform("Couldn't restart Cairn", error.localizedDescription + " Quit and open it again to finish updating.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: Alerts

    private func offer(_ update: Updates.Update) {
        let alert = NSAlert()
        alert.messageText = "Cairn \(update.version) is available"
        alert.informativeText = "You have \(Cairn.version)."
            + (canInstall ? " Cairn downloads it, checks it, and restarts." : " This copy of Cairn isn't in an Applications folder, so download the new version from GitHub.")
        if canInstall { alert.addButton(withTitle: "Install and Restart") }
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        let notes: NSApplication.ModalResponse = canInstall ? .alertSecondButtonReturn : .alertFirstButtonReturn
        if canInstall, answer == .alertFirstButtonReturn {
            Task { await install(update, restartNow: true) }
        } else if answer == notes {
            NSWorkspace.shared.open(update.page)
        }
    }

    private func offerRestart() {
        guard case .ready(let update) = phase else { return }
        let alert = NSAlert()
        alert.messageText = "Cairn \(update.version) is ready"
        alert.informativeText = "Restart Cairn to finish updating."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
