import Foundation

/// Applies a `RestorePlan` on macOS. Writes system state: only ever run it
/// against a throwaway user or VM during development (see CLAUDE.md).
///
/// Settings and the Dock are written with `defaults write <domain> <key> <plist>`,
/// then the processes that cache them are restarted.
public struct MacRestorer: Sendable {
    public var runner: CommandRunner
    /// Whether an app bundle exists on this Mac. Injected for tests.
    public var appExists: @Sendable (String) -> Bool
    public var displays: DisplaySystem
    public var defaultApps: DefaultAppsSystem
    public var wifi: WiFiSystem
    public var sshKeys: SSHKeySystem
    public var sharePasswords: SharePasswordSystem
    public var credentialFiles: CredentialFileSystem

    public init(
        runner: CommandRunner = ProcessRunner(policy: .restore),
        appExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        displays: DisplaySystem = CoreGraphicsDisplays(),
        defaultApps: DefaultAppsSystem = LaunchServicesDefaultApps(),
        wifi: WiFiSystem = CoreWLANWiFi(),
        sshKeys: SSHKeySystem = FileSSHKeys(),
        sharePasswords: SharePasswordSystem = KeychainSharePasswords(),
        credentialFiles: CredentialFileSystem = HomeCredentialFiles()
    ) {
        self.credentialFiles = credentialFiles
        self.wifi = wifi
        self.sshKeys = sshKeys
        self.sharePasswords = sharePasswords
        self.runner = runner
        self.appExists = appExists
        self.displays = displays
        self.defaultApps = defaultApps
    }

    /// Domains whose changes most apps only pick up after logging out and back in.
    static let logoutDomains: Set<String> = [
        "NSGlobalDomain", "com.apple.HIToolbox", "com.apple.symbolichotkeys",
        "com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad",
        "com.apple.driver.AppleBluetoothMultitouch.mouse",
    ]

    /// Settings in `plan` that will need a log out after restore (for previews).
    public static func logoutSettings(in plan: RestorePlan) -> [String] {
        plan.changes.compactMap { step in
            if case .setting(let s, _) = step, let d = s.adapter.macos?.domain, logoutDomains.contains(d) { return s.key }
            return nil
        }
    }

    /// AppleScript that switches Dark Mode on or off right away. Runs through
    /// System Events, so macOS asks the user once (Automation); Cairn never
    /// grants that itself.
    public static func darkModeScript(_ dark: Bool) -> String {
        "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
    }

    /// Processes that cache a preference domain and must restart to pick up changes.
    static let restarts: [String: String] = [
        "com.apple.dock": "Dock",
        "com.apple.spaces": "Dock",
        "com.apple.finder": "Finder",
        "com.apple.desktopservices": "Finder",
        "com.apple.menuextra.clock": "SystemUIServer",
        "com.apple.screencapture": "SystemUIServer",
        "com.apple.controlcenter": "ControlCenter",
    ]

    /// Preference domains macOS protects (TCC): `defaults write` fails with
    /// "Could not write domain" unless the user grants access by hand, which
    /// Cairn must not do for them. Verified in a VM for universalaccess.
    static let protectedDomains: [String: (category: String, reason: String)] = [
        "com.apple.universalaccess": ("accessibility",
            "macOS protects these; set them by hand in System Settings > Accessibility"),
        "com.apple.Safari": ("safari",
            "macOS protects Safari's settings; set them by hand in Safari > Settings"),
    ]

    /// Settings macOS resets unless the Mac is signed in to iCloud.
    static let iCloudKeys: Set<String> = [
        "com.apple.finder/FXICloudDriveEnabled",
        "com.apple.finder/FXICloudDriveDesktop",
        "com.apple.finder/FXICloudDriveDocuments",
    ]

    /// Which settings restore leaves for the post-restore checklist. Pass to `RestorePlan.make`.
    public static let manualStep: RestorePlan.ManualCheck = { item in
        guard let ref = item.adapter.macos else { return nil }
        if let p = protectedDomains[ref.domain] { return p }
        if iCloudKeys.contains("\(ref.domain)/\(ref.key)") {
            return ("icloud", "needs iCloud sign-in; turn on in System Settings > Apple Account > iCloud")
        }
        return nil
    }

    /// `backup` names the manifest, recorded with any Dock tiles left out for later.
    /// `secrets` holds the backup's encrypted secrets; `unlock` opens the vault,
    /// and is only called if a step needs a secret (so it prompts at most once).
    public func apply(_ plan: RestorePlan, backup: String = "", now: Date = Date(),
                      secrets: SecretsFile = SecretsFile(), unlock: (() throws -> VaultKey)? = nil,
                      progress: (@Sendable (String) -> Void)? = nil) -> RestoreReport {
        var key: VaultKey?
        var unlockError: String?
        func vaultKey() -> VaultKey? {
            if key == nil && unlockError == nil {
                do {
                    guard let unlock else { throw VaultError.noVault }
                    key = try unlock()
                } catch { unlockError = error.localizedDescription }
            }
            return key
        }
        var report = RestoreReport()
        var touched: [String] = []

        for step in plan.steps {
            switch step {
            case .commandLineTools:
                progress?("Opening Apple's Command Line Tools installer")
                let r = try? runner.run(Self.commandLineToolsCommand)
                // Exit 1 with "already installed" means they arrived meanwhile.
                let already = r?.stderr.contains("already installed") == true
                report.entries.append(.init(step: step, outcome: already ? .skipped("already installed")
                    : r?.exitCode == 0 ? .partial("Apple's installer is open; finish it, then run restore again for packages")
                    : .failed(r?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "couldn't run xcode-select"), written: nil))
                if !already {
                    report.manualSteps.append(.init(category: "command line tools",
                        text: "finish Apple's Command Line Tools installer, install Homebrew from https://brew.sh, then run restore again"))
                }

            case .packages(let items):
                var done: [String] = [], failed: [String] = []
                for (i, p) in items.enumerated() {
                    let name = p.resolvers["brew"] ?? p.id
                    progress?("Installing \(p.kind.rawValue) \(name) (\(i + 1) of \(items.count))")
                    let r = try? runner.run(Self.installCommand(p))
                    if r?.exitCode == 0 { done.append(p.uid) } else {
                        failed.append(name)
                        let why = r.map { Self.lastLine($0.stderr) } ?? "couldn't run brew"
                        report.manualSteps.append(.init(category: "packages", text: "\(p.kind.rawValue) \(name) didn't install: \(why)"))
                    }
                }
                let outcome: RestoreReport.Outcome = failed.isEmpty ? .applied
                    : done.isEmpty ? .failed("none installed: " + failed.prefix(5).joined(separator: ", "))
                    : .partial("\(failed.count) didn't install: " + failed.prefix(5).joined(separator: ", "))
                report.entries.append(.init(step: step, outcome: outcome, written: done.isEmpty ? nil : .packages(done)))

            case .appStore(let apps):
                var done: [String] = [], failed: [String] = []
                for (i, a) in apps.enumerated() {
                    progress?("Installing \(a.name) from the App Store (\(i + 1) of \(apps.count))")
                    let r = try? runner.run(Command("mas", ["install", a.id]))
                    if r?.exitCode == 0 { done.append(a.id) } else {
                        failed.append(a.name)
                        report.manualSteps.append(.init(category: "app store",
                            text: "install \(a.name) from the App Store (sign in first; it must be on your Apple Account)"))
                    }
                }
                let outcome: RestoreReport.Outcome = failed.isEmpty ? .applied
                    : done.isEmpty ? .failed("none installed (signed in to the App Store?)")
                    : .partial("\(failed.count) didn't install: " + failed.prefix(5).joined(separator: ", "))
                report.entries.append(.init(step: step, outcome: outcome, written: done.isEmpty ? nil : .appStore(done)))

            case .pending(_, _, let reason):
                report.entries.append(.init(step: step, outcome: .skipped(reason), written: nil))

            case .setting(let item, _):
                guard let ref = item.adapter.macos else {
                    report.entries.append(.init(step: step, outcome: .skipped("no macOS adapter"), written: nil))
                    continue
                }
                do {
                    let xml = try PlistXML.fragment(item.value, type: ref.type)
                    try write(domain: ref.domain, key: ref.key, xml: xml)
                    touched.append(ref.domain)
                    report.entries.append(.init(step: step, outcome: .applied, written: .setting(item.value)))
                } catch {
                    report.entries.append(.init(step: step, outcome: .failed("\(error)"), written: nil))
                }

            case .defaultApps(let handlers):
                var applied: [DefaultAppHandler] = [], missingApps = Set<String>(), refused: [DefaultAppHandler] = []
                for h in handlers {
                    guard defaultApps.isInstalled(bundleID: h.bundleID) else { missingApps.insert(h.bundleID); continue }
                    if defaultApps.current(for: h) == h.bundleID { applied.append(h); continue } // already so
                    // Read back: a browser change waits for the user to confirm macOS's dialog.
                    if defaultApps.set(h), defaultApps.current(for: h) == h.bundleID { applied.append(h) } else { refused.append(h) }
                }
                var notes: [String] = []
                if !missingApps.isEmpty { notes.append("\(handlers.count - applied.count - refused.count) left for \(missingApps.count) apps not installed") }
                if !refused.isEmpty { notes.append("\(refused.count) not taken (refused, or waiting for you to confirm)") }
                let outcome: RestoreReport.Outcome = applied.isEmpty ? .skipped(notes.joined(separator: "; "))
                    : notes.isEmpty ? .applied : .partial(notes.joined(separator: "; "))
                report.entries.append(.init(step: step, outcome: outcome, written: applied.isEmpty ? nil : .defaultApps(applied)))
                if !refused.isEmpty {
                    report.manualSteps.append(.init(category: "default apps",
                        text: "set these in Finder > Get Info > Open with: " + refused.map(\.summary).joined(separator: ", ")))
                }

            case .wifi(let networks):
                var saved: [String] = [], notes: [String] = [], places: [String: [String]] = [:]
                for n in networks {
                    guard n.hasPassword, let sealed = secrets.secrets[n.ref] else {
                        report.manualSteps.append(.init(category: "wi-fi", text: "join \(n.ssid) from the Wi-Fi menu and type its password (none was saved)"))
                        continue
                    }
                    guard let key = vaultKey() else { notes.append("\(n.ssid): vault not unlocked"); continue }
                    do {
                        var password = try key.open(sealed, ref: n.ref)
                        defer { Vault.zero(&password) }
                        if let place = wifi.savePassword(password, ssid: n.ssid), wifi.hasPassword(password, ssid: n.ssid) {
                            saved.append(n.ssid)
                            places[place, default: []].append(n.ssid)
                        } else {
                            notes.append("\(n.ssid): the Keychain didn't take the password")
                        }
                    } catch {
                        notes.append("\(n.ssid): couldn't decrypt (\(error.localizedDescription))")
                    }
                }
                if let unlockError { notes.append("vault: \(unlockError)") }
                // macOS adds a network to its list the first time it's joined (backups don't
                // record the security type needed to add it blind). Without root, CoreWLAN
                // saves to the login keychain (seen in VM testing); whether joining picks it
                // up there needs real Wi-Fi hardware to confirm, so say where it is.
                for (place, ssids) in places.sorted(by: { $0.key < $1.key }) {
                    report.manualSteps.append(.init(category: "wi-fi",
                        text: "pick \(ssids.joined(separator: ", ")) once in the Wi-Fi menu. The password is saved in your \(place); "
                            + "if macOS still asks for it, Keychain Access shows it (search for the network name)"))
                }
                let outcome: RestoreReport.Outcome = saved.isEmpty
                    ? (notes.isEmpty ? .skipped("no passwords saved in the backup") : .failed(notes.joined(separator: "; ")))
                    : notes.isEmpty ? .applied : .partial(notes.joined(separator: "; "))
                report.entries.append(.init(step: step, outcome: outcome, written: saved.isEmpty ? nil : .wifi(saved)))

            case .secrets(let items):
                var done: [String] = [], notes: [String] = []
                for item in items {
                    guard item.hasSecret, let sealed = secrets.secrets[item.ref] else {
                        report.manualSteps.append(.init(category: Self.checklistCategory(item.type),
                            text: "\(item.title) wasn't saved in the backup; copy it over by hand"))
                        continue
                    }
                    guard let key = vaultKey() else { notes.append("\(item.title): vault not unlocked"); continue }
                    do {
                        var secret = try key.open(sealed, ref: item.ref)
                        defer { Vault.zero(&secret) }
                        let outcome: Bool?
                        switch item.type {
                        case "ssh": outcome = restoreSSHKey(secret, item: item, report: &report)
                        case "token": outcome = restoreCredentialFile(secret, item: item, report: &report)
                        default: outcome = restoreSharePassword(secret, item: item, report: &report)
                        }
                        switch outcome {
                        case .some(true): done.append(item.title)
                        case .some(false): notes.append("\(item.title): couldn't save it")
                        case nil: break // already there, or left for the checklist
                        }
                    } catch {
                        notes.append("\(item.title): couldn't decrypt (\(error.localizedDescription))")
                    }
                }
                if let unlockError { notes.append("vault: \(unlockError)") }
                let outcome: RestoreReport.Outcome = done.isEmpty
                    ? (notes.isEmpty ? .skipped("nothing new to restore") : .failed(notes.joined(separator: "; ")))
                    : notes.isEmpty ? .applied : .partial(notes.joined(separator: "; "))
                report.entries.append(.init(step: step, outcome: outcome, written: done.isEmpty ? nil : .secrets(done)))

            case .wallpaper(let w, _):
                let (applied, notes) = applyWallpaper(w)
                let outcome: RestoreReport.Outcome = applied.isEmpty ? .skipped(notes.joined(separator: "; "))
                    : notes.isEmpty ? .applied : .partial(notes.joined(separator: "; "))
                report.entries.append(.init(step: step, outcome: outcome, written: applied.isEmpty ? nil : .wallpaper(applied)))
                for n in notes { report.manualSteps.append(.init(category: "wallpaper", text: n)) }

            case .dock(let layout, _):
                let (tiles, missing) = dockTiles(layout.apps)
                do {
                    try write(domain: DockScanner.domain, key: "persistent-apps", xml: Self.dockXML(tiles))
                    touched.append(DockScanner.domain)
                    let outcome: RestoreReport.Outcome = missing.isEmpty ? .applied
                        : .partial("left out \(missing.count) not installed: "
                                   + missing.map(RestorePlan.shortName).joined(separator: ", "))
                    report.entries.append(.init(step: step, outcome: outcome, written: .dock(tiles)))
                    report.waitingForDock = PendingDock.entries(missing: missing, backupDock: layout.apps,
                                                                backup: backup, now: now)
                } catch {
                    report.entries.append(.init(step: step, outcome: .failed("\(error)"), written: nil))
                }
            }
        }

        var seen = Set<String>()
        for process in touched.compactMap({ Self.restarts[$0] }) where seen.insert(process).inserted {
            // killall exits 1 when the process isn't running; that's fine.
            _ = try? runner.run(Command("killall", [process]))
            report.restarted.append(process)
        }

        // Dark Mode: the preference is written, but the screen only changes after a
        // log out unless something asks the system to switch now.
        var appliedLive = Set<String>()
        if let style = appliedAppearance(report), !followsAutoAppearance(plan) {
            let dark = style == "Dark"
            if let r = try? runner.run(Command("osascript", ["-e", Self.darkModeScript(dark)])), r.exitCode == 0 {
                appliedLive.insert(style)
            } else {
                report.manualSteps.append(.init(category: "appearance",
                    text: "turn \(dark ? "on" : "off") Dark Mode in System Settings > Appearance (Cairn wasn't allowed to control System Events), or log out"))
            }
        }
        report.needsLogout = report.entries.compactMap { e in
            guard e.outcome == .applied || Self.isPartial(e.outcome), case .setting(let s, _) = e.step,
                  let ref = s.adapter.macos, Self.logoutDomains.contains(ref.domain) else { return nil }
            if ref.key == "AppleInterfaceStyle", !appliedLive.isEmpty { return nil }
            return s.key
        }
        return report
    }

    /// true = written and read back, false = failed, nil = nothing to do or left for the checklist.
    func restoreSSHKey(_ key: Data, item: SecretRestore, report: inout RestoreReport) -> Bool? {
        guard let name = SSHKeyScanner.file(ref: item.ref) else { return false }
        if var existing = sshKeys.existing(name) {
            defer { Vault.zero(&existing) }
            if existing != key {
                report.manualSteps.append(.init(category: "ssh",
                    text: "~/.ssh/\(name) already exists and differs from the backup; Cairn left it alone"))
            }
            return nil
        }
        do { try sshKeys.write(key, name: name) } catch { return false }
        guard var back = sshKeys.existing(name) else { return false }
        defer { Vault.zero(&back) }
        guard back == key else { return false }
        if !sshKeys.writePublicKey(for: name) {
            report.manualSteps.append(.init(category: "ssh",
                text: "\(name).pub wasn't recreated (the key has a passphrase, or a .pub is already there); run ssh-keygen -y -f ~/.ssh/\(name) > ~/.ssh/\(name).pub if you need it"))
        }
        return true
    }

    static let commandLineToolsCommand = Command("xcode-select", ["--install"])

    /// `brew tap x`, `brew install --formula x`, or `brew install --cask x`.
    public static func installCommand(_ p: PackageItem) -> Command {
        let name = p.resolvers["brew"] ?? p.id
        switch p.kind {
        case .tap: return Command("brew", ["tap", name])
        case .formula: return Command("brew", ["install", "--formula", name])
        case .cask: return Command("brew", ["install", "--cask", name])
        }
    }

    static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "no details"
    }

    /// Which install tools this Mac has. Read-only.
    public static func detectEnvironment(runner: CommandRunner = ProcessRunner()) -> RestoreEnvironment {
        func ok(_ c: Command) -> Bool { (try? runner.run(c))?.exitCode == 0 }
        return RestoreEnvironment(commandLineTools: ok(Command("xcode-select", ["-p"])),
                                  homebrew: ok(Command("brew", ["--version"])),
                                  mas: ok(Command("mas", ["version"])))
    }

    static func checklistCategory(_ type: String) -> String {
        switch type {
        case "ssh": return "ssh"
        case "token": return "tokens"
        default: return "shares"
        }
    }

    /// Same rules as SSH keys: created 0600, never replacing a file that's there.
    func restoreCredentialFile(_ data: Data, item: SecretRestore, report: inout RestoreReport) -> Bool? {
        guard let path = CredentialFiles.path(ref: item.ref) else { return false }
        if var existing = credentialFiles.existing(path) {
            defer { Vault.zero(&existing) }
            if existing != data {
                report.manualSteps.append(.init(category: "tokens",
                    text: "~/\(path) already exists and differs from the backup; Cairn left it alone"))
            }
            return nil
        }
        do { try credentialFiles.write(data, path: path) } catch { return false }
        guard var back = credentialFiles.existing(path) else { return false }
        defer { Vault.zero(&back) }
        return back == data
    }

    func restoreSharePassword(_ password: Data, item: SecretRestore, report: inout RestoreReport) -> Bool? {
        // `smb/alex@nas.example`
        let title = item.title
        guard let slash = title.firstIndex(of: "/"), let at = title.lastIndex(of: "@"), slash < at else { return false }
        let scheme = String(title[..<slash]), user = String(title[title.index(after: slash)..<at]),
            host = String(title[title.index(after: at)...])
        if sharePasswords.exists(scheme: scheme, user: user, host: host) { return nil } // never replace one
        guard sharePasswords.add(password, scheme: scheme, user: user, host: host),
              sharePasswords.matches(password, scheme: scheme, user: user, host: host) else { return false }
        report.manualSteps.append(.init(category: "shares",
            text: "the first time you connect to \(host), macOS may ask to let Finder use the saved password: choose Always Allow"))
        return true
    }

    static func isPartial(_ o: RestoreReport.Outcome) -> Bool { if case .partial = o { return true } else { return false } }

    /// The appearance (`Dark`, or `Light` when the key was set to something else)
    /// if restore just wrote it.
    func appliedAppearance(_ report: RestoreReport) -> String? {
        for e in report.entries where e.outcome == .applied {
            if case .setting(let s, _) = e.step, s.adapter.macos?.domain == "NSGlobalDomain",
               s.adapter.macos?.key == "AppleInterfaceStyle", case .string(let v) = s.value {
                return v == "Dark" ? "Dark" : "Light"
            }
        }
        return nil
    }

    /// The backup uses Auto appearance; macOS picks light or dark itself.
    func followsAutoAppearance(_ plan: RestorePlan) -> Bool {
        plan.steps.contains { step in
            if case .setting(let s, _) = step, s.adapter.macos?.key == "AppleInterfaceStyleSwitchesAutomatically" {
                return s.value == .bool(true) || s.value == .int(1)
            }
            return false
        }
    }

    /// Sets each saved desktop picture on the display with the same id. Pictures
    /// whose display or image file isn't on this Mac are reported, not guessed.
    func applyWallpaper(_ w: WallpaperLayout) -> (applied: [DesktopPicture], notes: [String]) {
        let raw = displays.onlineDisplays()
        let byID = Dictionary(DisplayScanner.identities(raw).map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let main = raw.first(where: \.main) ?? raw.first
        var applied: [DesktopPicture] = [], notes: [String] = []
        for p in w.pictures {
            guard FileManager.default.fileExists(atPath: p.path) else {
                notes.append("\(RestorePlan.shortName(p.path)) isn't on this Mac (Cairn doesn't copy images); set the desktop picture by hand")
                continue
            }
            // None of the saved displays is here (a new Mac): the first picture
            // goes on the main display.
            let noneMatch = !w.pictures.contains { byID[$0.display] != nil }
            let target = byID[p.display] ?? (noneMatch && p == w.pictures.first ? main?.displayID : nil)
            guard let display = target else {
                if !noneMatch { notes.append("display \(p.display) isn't connected") }
                continue
            }
            do {
                try displays.setDesktopPicture(p.path, display: display)
                let id = DisplayScanner.identities(raw)[display] ?? p.display
                applied.append(DesktopPicture(display: id, path: p.path))
            } catch {
                notes.append("couldn't set \(RestorePlan.shortName(p.path)): \(error)")
            }
        }
        return (applied, notes)
    }

    private func write(domain: String, key: String, xml: String) throws {
        _ = try runner.output(Command("defaults", ["write", domain, key, xml]))
    }

    /// Tiles that can be restored here, plus the apps that aren't installed.
    public func dockTiles(_ apps: [String]) -> (tiles: [String], missing: [String]) {
        var tiles: [String] = []
        var missing: [String] = []
        for app in apps {
            if ["spacer", "small-spacer", "flex-spacer"].contains(app) { tiles.append(app); continue }
            guard app.hasPrefix("/") else { missing.append(app); continue }
            if appExists(app) { tiles.append(app) } else { missing.append(app) }
        }
        return (tiles, missing)
    }

    static func dockXML(_ tiles: [String]) -> String {
        let items = tiles.map { tile -> String in
            switch tile {
            case "spacer": return "<dict><key>tile-data</key><dict/><key>tile-type</key><string>spacer-tile</string></dict>"
            case "small-spacer": return "<dict><key>tile-data</key><dict/><key>tile-type</key><string>small-spacer-tile</string></dict>"
            case "flex-spacer": return "<dict><key>tile-data</key><dict/><key>tile-type</key><string>flex-spacer-tile</string></dict>"
            default:
                let url = URL(fileURLWithPath: tile, isDirectory: true).absoluteString
                return "<dict><key>tile-data</key><dict><key>file-data</key><dict>"
                    + "<key>_CFURLString</key><string>\(PlistXML.escape(url))</string>"
                    + "<key>_CFURLStringType</key><integer>15</integer>"
                    + "</dict></dict><key>tile-type</key><string>file-tile</string></dict>"
            }
        }
        return "<array>" + items.joined() + "</array>"
    }
}

/// Writes a `SettingValue` as an XML property-list fragment that `defaults write` accepts.
enum PlistXML {
    enum Error: Swift.Error, CustomStringConvertible {
        case badValue(String)
        var description: String {
            switch self { case .badValue(let s): return "can't write value: \(s)" }
        }
    }

    /// `type` is the adapter's original plist type, so dates, data and whole-number
    /// floats are written back as what they were.
    static func fragment(_ value: SettingValue, type: String) throws -> String {
        switch (type, value) {
        case ("bool", .bool(let b)): return b ? "<true/>" : "<false/>"
        case ("int", .int(let i)): return "<integer>\(i)</integer>"
        case ("float", .int(let i)): return "<real>\(i)</real>"
        case ("float", .double(let d)): return "<real>\(d)</real>"
        case ("date", .string(let s)):
            guard ISO8601DateFormatter().date(from: s) != nil else { throw Error.badValue("date \(s)") }
            return "<date>\(escape(s))</date>"
        case ("data", .string(let s)):
            guard Data(base64Encoded: s) != nil else { throw Error.badValue("data") }
            return "<data>\(s)</data>"
        default: return generic(value)
        }
    }

    /// Nested values have no recorded types; write them as they decoded.
    static func generic(_ value: SettingValue) -> String {
        switch value {
        case .bool(let b): return b ? "<true/>" : "<false/>"
        case .int(let i): return "<integer>\(i)</integer>"
        case .double(let d): return "<real>\(d)</real>"
        case .string(let s): return "<string>\(escape(s))</string>"
        case .array(let a): return "<array>" + a.map(generic).joined() + "</array>"
        case .dict(let d):
            return "<dict>" + d.keys.sorted().map { "<key>\(escape($0))</key>" + generic(d[$0]!) }.joined() + "</dict>"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
