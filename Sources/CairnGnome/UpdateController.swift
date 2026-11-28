import CairnCore
import Foundation

/// What the update banner and the Preferences row show.
struct UpdateState {
    enum Phase: Equatable {
        case idle, checking, upToDate, available, installing, installed
        case failed(String)
    }

    var install = LinuxInstall.current()
    /// The .deb added Cairn's apt repository, so Software Updater brings new versions.
    var viaSoftwareUpdater = FileManager.default.fileExists(atPath: "/etc/apt/sources.list.d/cairn.sources")
    var phase = Phase.idle
    var update: Updates.Update?

    var bannerVisible: Bool { [.available, .installing, .installed].contains(phase) }

    var bannerText: String {
        guard let update else { return "" }
        switch phase {
        case .installing: return "Installing Cairn \(update.version)…"
        case .installed: return "Cairn \(update.version) is installed. Restart Cairn to finish."
        default:
            if install == .deb && viaSoftwareUpdater { return LinuxUpdates.availableText(update) + " in Software Updater" }
            return LinuxUpdates.availableText(update)
        }
    }

    /// The banner's button: Update for the AppImage, Download for the .deb and a
    /// copy built from source, Restart once the new AppImage is in place.
    var bannerButton: String {
        switch phase {
        case .installed: return "Restart"
        case .installing: return ""
        default:
            if case .appImage = install { return "Update" }
            return install == .deb && viaSoftwareUpdater ? "Open Software Updater" : "Download"
        }
    }

    var preferencesText: String {
        switch phase {
        case .idle: return "Cairn \(Cairn.version)"
        case .checking: return "Checking for updates…"
        case .upToDate: return "Cairn \(Cairn.version) is up to date"
        case .available, .installing, .installed: return bannerText
        case .failed(let why): return why
        }
    }
}

/// Cairn's own updates, from GitHub Releases. The AppImage replaces itself
/// (AppImageUpdater, which checks the download's checksum first); the .deb
/// opens the release page so the user installs the new file.
extension MainView {
    /// GitHub, or in a debug build with `CAIRN_UPDATE_TEST=<folder>`, files in
    /// that folder standing in for it (see LinuxUpdates.localFetch).
    nonisolated static var updateFetch: AppImageUpdater.Fetch {
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["CAIRN_UPDATE_TEST"], !folder.isEmpty {
            return LinuxUpdates.localFetch(folder: URL(fileURLWithPath: folder))
        }
        #endif
        return AppImageUpdater.download
    }

    /// On launch: quietly, at most once a day, and only for the AppImage and the .deb.
    func checkForUpdatesOnLaunch() {
        guard update.install.checksAutomatically,
              LinuxUpdates.due(lastCheck: LinuxUpdates.lastCheck(in: AppFolder.defaults)) else { return }
        checkForUpdates(quietly: true)
    }

    /// `quietly`: on launch, where a failed check (offline, GitHub busy) says nothing.
    func checkForUpdates(quietly: Bool = false) {
        guard ![.checking, .installing].contains(update.phase) else { return }
        update.phase = .checking
        let platform = update.install.platform
        let fetch = Self.updateFetch
        Task.detached {
            do {
                let found = try await LinuxUpdates.check(platform: platform, fetch: fetch)
                LinuxUpdates.recordCheck(in: AppFolder.defaults)
                onMainLoop {
                    update.update = found
                    update.phase = found == nil ? .upToDate : .available
                }
            } catch {
                let why = "Couldn't check for updates: \(error.localizedDescription)"
                onMainLoop { update.phase = quietly ? .idle : .failed(why) }
            }
        }
    }

    func updateBannerClicked() {
        switch update.phase {
        case .installed: restartIntoUpdate()
        case .available:
            guard let found = update.update else { return }
            if case .appImage(let file) = update.install {
                installUpdate(found, appImage: file)
            } else if update.install == .deb && update.viaSoftwareUpdater {
                Self.openSoftwareUpdater(fallback: found.page)
            } else {
                Self.openInFiles(found.page)
            }
        default: break
        }
    }

    func installUpdate(_ found: Updates.Update, appImage: URL) {
        update.phase = .installing
        let updater = AppImageUpdater(appImage: appImage, fetch: Self.updateFetch)
        Task.detached {
            do {
                try await updater.install(found)
                onMainLoop { update.phase = .installed }
            } catch {
                let why = error.localizedDescription
                onMainLoop {
                    update.phase = .failed("Cairn \(found.version) wasn't installed. \(why)")
                    toastText = "Update failed: \(why)"
                    toast.signal()
                }
            }
        }
    }

    /// Ubuntu's Software Updater, which installs the new .deb from Cairn's apt repository.
    static func openSoftwareUpdater(fallback: URL) {
        let app = "/usr/bin/update-manager"
        guard FileManager.default.isExecutableFile(atPath: app) else { openInFiles(fallback); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: app)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) == nil { openInFiles(fallback) }
    }

    /// Opens the new AppImage once this window has closed (GNOME allows one Cairn at a time).
    func restartIntoUpdate() {
        guard case .appImage(let file) = update.install else { return }
        let command = LinuxUpdates.relaunchCommand(appImage: file, pid: ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            exit(0)
        } catch {
            toastText = "Couldn't restart Cairn. Close it and open it again."
            toast.signal()
        }
    }
}
