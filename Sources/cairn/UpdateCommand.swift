#if os(macOS)
import ArgumentParser
import CairnCore
import Foundation

/// `cairn update`: the same update check as the app's Check for Updates.
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for a newer Cairn. Installs it only with --apply.",
        discussion: """
            Asks GitHub for the latest Cairn release and says whether it's newer. With
            --apply it downloads it, checks it against the release's checksum, its bundle
            id, version and code signature, then replaces the Cairn.app this command
            lives in (Cairn.app/Contents/MacOS/cairn, in an Applications folder). Quit
            and reopen Cairn afterwards to use the new version.
            """
    )

    @Flag(name: .long, help: "Download and install the update.")
    var apply = false

    func run() async throws {
        let updater = AppUpdater()
        print("This is Cairn \(Cairn.version).")
        guard let update = try await updater.check() else {
            print("It's up to date.")
            return
        }
        print("Cairn \(update.version) is available: \(update.page.absoluteString)")
        guard apply else {
            print("Dry run: nothing installed. Add --apply to install it.")
            return
        }
        guard let app = AppUpdater.installedApp() else {
            throw ValidationError("This cairn isn't inside Cairn.app in an Applications folder, so there's nothing to update. Download the new version from the page above.")
        }
        print("Downloading \(update.archiveName)…")
        let staged = try await updater.prepare(update, replacing: app)
        try updater.install(staged, over: app)
        print("Installed Cairn \(update.version) at \(app.path). Quit and reopen Cairn to use it.")
    }
}
#endif
