import Foundation
import Testing
@testable import CairnCore

/// Linux catching up with the Mac and Windows: fonts, layout, secrets, shares.
/// Made-up files in throwaway folders.
@Suite struct LinuxParityTests {
    static func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Fonts

    @Test func linuxFontsAreFoundInBothFoldersAndSubfolders() throws {
        let home = try Self.temp()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write("font a", to: home.appendingPathComponent(".local/share/fonts/Family/Alpha-Regular.ttf"))
        try Self.write("font b", to: home.appendingPathComponent(".fonts/Beta.otf"))
        try Self.write("same name", to: home.appendingPathComponent(".fonts/Alpha-Regular.ttf"))
        try Self.write("not a font", to: home.appendingPathComponent(".local/share/fonts/readme.txt"))
        try Self.write("hidden", to: home.appendingPathComponent(".local/share/fonts/.cache/Gamma.ttf"))
        let found = try FontsScanner(home: home.path, linux: true).scan(using: FixtureRunner()).fonts
        #expect(found.map(\.file) == ["Alpha-Regular.ttf", "Beta.otf"])
        #expect(found[0].source?.hasSuffix(".local/share/fonts/Family/Alpha-Regular.ttf") == true)
    }

    static func fontBackup() throws -> (Manifest, URL) {
        let store = try temp()
        let data = Data("font bytes".utf8)
        let sha = AppImageUpdater.sha256Hex(data)
        try data.write(to: store.appendingPathComponent("\(sha).ttf"))
        let m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Date(timeIntervalSince1970: 0),
                         fonts: [FontItem(file: "Alpha-Regular.ttf", name: "Alpha", sha256: sha, size: data.count),
                                 FontItem(file: "Old.dfont", name: "Old", sha256: String(repeating: "a", count: 64), size: 1)])
        return (m, store)
    }

    /// Runs the kit's setup.sh with a throwaway home and only harmless tools on PATH.
    static func runKit(_ m: Manifest, fontsFrom: URL?, home: URL, apply: Bool) throws -> String {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try PlatformExport.make(m, for: .linux).write(into: dir, fontsFrom: fontsFrom)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent("setup.sh").path] + (apply ? ["--apply"] : [])
        p.environment = ["PATH": (try PlatformExportTests.systemTools(in: dir)).path, "HOME": home.path]
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func kitInstallsMissingFontsOnly() throws {
        let (m, store) = try Self.fontBackup()
        let home = try Self.temp()
        defer { for u in [store, home] { try? FileManager.default.removeItem(at: u) } }
        let kit = PlatformExport.make(m, for: .linux)
        #expect(kit.fonts.map(\.file) == ["Alpha-Regular.ttf"]) // .dfont is Mac-only

        #expect(try Self.runKit(m, fontsFrom: store, home: home, apply: false).contains("would install Alpha-Regular.ttf"))
        #expect(try Self.runKit(m, fontsFrom: nil, home: home, apply: false).contains("Alpha-Regular.ttf isn't in the backup's fonts folder"))

        let applied = try Self.runKit(m, fontsFrom: store, home: home, apply: true)
        #expect(applied.contains("installed Alpha-Regular.ttf"))
        let installed = home.appendingPathComponent(".local/share/fonts/Alpha-Regular.ttf")
        #expect(try Data(contentsOf: installed) == Data("font bytes".utf8))
        #expect(try Self.runKit(m, fontsFrom: store, home: home, apply: false).contains("Alpha-Regular.ttf is already installed"))
    }

    @Test func aFontCopyThatDoesntMatchIsLeftOut() throws {
        var (m, store) = try Self.fontBackup()
        let home = try Self.temp()
        defer { for u in [store, home] { try? FileManager.default.removeItem(at: u) } }
        m.fonts[0].sha256 = String(repeating: "b", count: 64)
        #expect(try Self.runKit(m, fontsFrom: store, home: home, apply: false).contains("isn't in the backup's fonts folder"))
    }

    // MARK: GNOME-only settings

    @Test func gnomeOnlySettingsAreReadAndWrittenBackAsIs() throws {
        let r = FixtureRunner()
        for m in GnomeSettings.mappings + GnomeSettings.nativeMappings { // everything else: schema not installed
            r.stub(Command("gsettings", ["get", m.schema, m.gsettingsKey]), stdout: "", stderr: "No such schema", exitCode: 1)
        }
        r.stub(Command("gsettings", ["get", "org.gnome.shell", "favorite-apps"]), stdout: "['org.gnome.Nautilus.desktop', 'firefox_firefox.desktop']\n")
        r.stub(Command("gsettings", ["get", "org.gnome.desktop.background", "picture-uri"]), stdout: "'file:///home/someone/Pictures/My%20Hill.jpg'\n")
        r.stub(Command("gsettings", ["get", "org.gnome.settings-daemon.plugins.color", "night-light-temperature"]), stdout: "uint32 3500\n")
        let found = try GnomeSettingsScanner().scan(using: r).settings
        let fav = try #require(found.first { $0.key == "dock.favorites" })
        #expect(fav.value == .string("['org.gnome.Nautilus.desktop', 'firefox_firefox.desktop']"))
        #expect(SettingCategory.classify(fav) == .lookAndLayout)
        #expect(SettingCategory.groupName(for: fav, in: .lookAndLayout) == "Dock")
        #expect(ItemLabels.title(settingKey: "dock.favorites") == "Apps pinned to the dock")
        let warm = try #require(found.first { $0.key == "display.night_light_temperature" })
        #expect(SettingCategory.classify(warm) == .systemSettings)

        let m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Date(timeIntervalSince1970: 0),
                         settings: found)
        let writes = PlatformExport.make(m, for: .linux).gsettings
        #expect(writes.contains(GSettingsWrite(schema: "org.gnome.shell", key: "favorite-apps",
                                               value: "['org.gnome.Nautilus.desktop', 'firefox_firefox.desktop']")))
        #expect(writes.contains(GSettingsWrite(schema: "org.gnome.settings-daemon.plugins.color", key: "night-light-temperature", value: "uint32 3500")))
        // A Mac or Windows kit has nowhere to put them.
        #expect(PlatformExport.make(m, for: .windows).registry.isEmpty)
    }

    @Test func onlyKnownGnomeKeysAreWrittenBack() {
        let made = SettingItem(key: "dock.favorites", value: .string("['x.desktop']"), platforms: ["linux"],
                               adapter: SettingAdapters(gnome: GSettingsRef(schema: "org.evil.schema", key: "anything")))
        // The write uses Cairn's own schema and key for the name, never the manifest's.
        #expect(GnomeSettings.nativeWrite(made) == GSettingsWrite(schema: "org.gnome.shell", key: "favorite-apps", value: "['x.desktop']"))
        let unknown = SettingItem(key: "gnome.something_else", value: .string("true"), platforms: ["linux"],
                                  adapter: SettingAdapters(gnome: GSettingsRef(schema: "org.evil.schema", key: "anything")))
        #expect(GnomeSettings.nativeWrite(unknown) == nil)
    }

    @Test func aWallpaperThatIsntHereIsSkipped() throws {
        let home = try Self.temp(), bin = try Self.temp()
        defer { for u in [home, bin] { try? FileManager.default.removeItem(at: u) } }
        let picture = home.appendingPathComponent("Pictures/My Hill.jpg")
        let gsettings = bin.appendingPathComponent("gsettings")
        try Self.write("#!/bin/bash\ncase \"$1\" in get) echo \"'file:///old.png'\";; writable) echo true;; set) echo \"SET $3 $4\";; esac\n", to: gsettings)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gsettings.path)
        let uri = "'file://" + picture.path.replacingOccurrences(of: " ", with: "%20") + "'"
        let m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Date(timeIntervalSince1970: 0),
                         settings: [SettingItem(key: "desktop.wallpaper", value: .string(uri), platforms: ["linux"],
                                                adapter: SettingAdapters(gnome: GSettingsRef(schema: "org.gnome.desktop.background", key: "picture-uri")))])
        func run(_ apply: Bool) throws -> String {
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let folder = try PlatformExport.make(m, for: .linux).write(into: dir)
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [folder.appendingPathComponent("setup.sh").path] + (apply ? ["--apply"] : [])
            p.environment = ["PATH": bin.path + ":" + (try PlatformExportTests.systemTools(in: dir)).path, "HOME": home.path]
            p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try run(false).contains("skipped picture-uri (the picture isn't on this computer: \(picture.path))"))
        try Self.write("jpg", to: picture)
        #expect(try run(false).contains("would change picture-uri from 'file:///old.png' to \(uri)"))
        #expect(try run(true).contains("SET picture-uri \(uri)"))
    }

    // MARK: Login items and default apps

    static let mimeapps = """
    [Added Associations]
    text/plain=org.gnome.TextEditor.desktop;

    [Default Applications]
    x-scheme-handler/http=brave-browser.desktop;firefox_firefox.desktop;
    text/html=brave-browser.desktop
    bad type=evil.desktop
    image/png=../../evil.desktop
    """

    @Test func loginItemsAndDefaultAppsAreRead() throws {
        let home = try Self.temp()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write("[Desktop Entry]\nName=Chat\nExec=chat-app --hidden\n", to: home.appendingPathComponent(".config/autostart/chat-app.desktop"))
        try Self.write("[Desktop Entry]\nExec=x\n", to: home.appendingPathComponent(".config/autostart/notes.txt"))
        try Self.write(Self.mimeapps, to: home.appendingPathComponent(".config/mimeapps.list"))
        let found = try GnomeStartupScanner(home: home.path).scan(using: FixtureRunner()).settings
        #expect(found.map(\.key) == ["login_items.autostart", "default_apps.handlers"])
        #expect(found[0].value == .array([.dict(["file": .string("chat-app.desktop"),
                                                  "content": .string("[Desktop Entry]\nName=Chat\nExec=chat-app --hidden\n")])]))
        #expect(found[1].value == .dict(["x-scheme-handler/http": .string("brave-browser.desktop"), "text/html": .string("brave-browser.desktop")]))
        #expect(SettingCategory.classify(found[0]) == .lookAndLayout)
        #expect(SettingCategory.groupName(for: found[1], in: .lookAndLayout) == "Default apps")
    }

    @Test func kitAddsLoginItemsAndDefaultAppsOnlyWhereTheAppIsHere() throws {
        let home = try Self.temp(), bin = try Self.temp()
        defer { for u in [home, bin] { try? FileManager.default.removeItem(at: u) } }
        let log = bin.appendingPathComponent("xdg.log").path
        try Self.write("#!/bin/bash\n[ \"$1\" = query ] && { echo firefox_firefox.desktop; exit 0; }\necho \"$*\" >> '\(log)'\n",
                       to: bin.appendingPathComponent("xdg-mime"))
        try Self.write("#!/bin/bash\nexit 0\n", to: bin.appendingPathComponent("chat-app"))
        for t in ["xdg-mime", "chat-app"] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(t).path) }
        try Self.write("[Desktop Entry]\n", to: home.appendingPathComponent(".local/share/applications/brave-browser.desktop"))

        let m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Date(timeIntervalSince1970: 0), settings: [
            SettingItem(key: "login_items.autostart", value: .array([
                .dict(["file": .string("chat-app.desktop"), "content": .string("[Desktop Entry]\nExec=env A=1 chat-app --hidden\n")]),
                .dict(["file": .string("gone.desktop"), "content": .string("[Desktop Entry]\nExec=/opt/gone/run\n")]),
                .dict(["file": .string("../escape.desktop"), "content": .string("x")]),
            ]), platforms: ["linux"], adapter: SettingAdapters()),
            SettingItem(key: "default_apps.handlers", value: .dict([
                "x-scheme-handler/http": .string("brave-browser.desktop"), "text/plain": .string("missing.desktop"),
            ]), platforms: ["linux"], adapter: SettingAdapters()),
        ])
        let kit = PlatformExport.make(m, for: .linux)
        #expect(kit.autostart.map(\.file) == ["chat-app.desktop", "gone.desktop"])
        #expect(kit.settingsLeft == 0)
        func run(_ apply: Bool) throws -> String {
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let folder = try kit.write(into: dir)
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [folder.appendingPathComponent("setup.sh").path] + (apply ? ["--apply"] : [])
            p.environment = ["PATH": bin.path + ":" + (try PlatformExportTests.systemTools(in: dir)).path, "HOME": home.path]
            p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let dry = try run(false)
        #expect(dry.contains("would add chat-app.desktop (opens: env A=1 chat-app --hidden)"))
        #expect(dry.contains("skipped gone.desktop: /opt/gone/run isn't installed here"))
        #expect(dry.contains("would open x-scheme-handler/http with brave-browser.desktop (now firefox_firefox.desktop)"))
        #expect(dry.contains("skipped text/plain: missing.desktop isn't installed here"))

        let applied = try run(true)
        #expect(applied.contains("added chat-app.desktop"))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/autostart/chat-app.desktop").path))
        #expect(try String(contentsOfFile: log, encoding: .utf8).contains("default brave-browser.desktop x-scheme-handler/http"))
        #expect(try run(false).contains("chat-app.desktop is already set up"))
    }

    // MARK: Secrets

    @Test func savedWiFiNetworksComeFromNetworkManager() throws {
        let r = FixtureRunner()
        r.stub(Command("nmcli", LinuxWiFiScanner.listArgs), stdout: """
        Home Network:802-11-wireless
        Wired connection 1:802-3-ethernet
        Cafe\\:Guest:802-11-wireless
        Home Network:802-11-wireless
        lo:loopback
        """)
        let refs = try LinuxWiFiScanner().scan(using: r).sensitive
        #expect(refs.map(\.ref) == ["vault://wifi/Home Network", "vault://wifi/Cafe:Guest"])
        #expect(refs.allSatisfy { !$0.include })
    }

    @Test func wifiPasswordIsReadOnlyWithTheExactCommand() throws {
        let r = FixtureRunner(policy: .secretReads)
        r.stub(LinuxWiFiPasswords.command(name: "Home Network"), stdout: "not-a-real-password\n")
        r.stub(LinuxWiFiPasswords.command(name: "Open Cafe"), stdout: "\n")
        #expect(try LinuxWiFiPasswords.read(name: "Home Network", using: r) == Data("not-a-real-password".utf8))
        #expect(try LinuxWiFiPasswords.read(name: "Open Cafe", using: r) == nil)

        #expect(CommandPolicy.secretReads.allows(LinuxWiFiPasswords.command(name: "Home Network")))
        #expect(!CommandPolicy.readOnly.allows(LinuxWiFiPasswords.command(name: "Home Network")))
        #expect(CommandPolicy.readOnly.allows(Command("nmcli", LinuxWiFiScanner.listArgs)))
        #expect(!CommandPolicy.secretReads.allows(Command("nmcli", ["connection", "delete", "id", "Home Network"])))
        #expect(!CommandPolicy.secretReads.allows(Command("nmcli", ["--show-secrets", "connection", "show"])))
    }

    @Test func linuxScansTheSensitiveSourcesToo() {
        #expect(SetupScanner.Source.linux.contains(.wifi) && SetupScanner.Source.linux.contains(.ssh) && SetupScanner.Source.linux.contains(.tokens))
    }

    final class FakeSecretTool: @unchecked Sendable {
        var store: [String: Data] = [:]
        var calls: [[String]] = []
        let lock = NSLock()
        func run(_ args: [String], _ input: Data?) -> (status: Int32, output: Data) {
            lock.lock(); defer { lock.unlock() }
            calls.append(args)
            let id = args.last ?? ""
            switch args.first {
            case "store": store[id] = input; return (0, Data())
            case "lookup": return store[id].map { (0, $0) } ?? (1, Data())
            case "clear": store[id] = nil; return (0, Data())
            default: return (2, Data())
            }
        }
    }

    @Test func vaultKeyIsRememberedInTheKeyringThroughStdin() throws {
        let fake = FakeSecretTool()
        let cache = SecretToolVaultKeyCache(run: { fake.run($0, $1) })
        let key = try Vault.create(password: "not a real password").key
        #expect(cache.load(vaultID: "abc123") == nil)
        try cache.save(key, vaultID: "abc123")
        let loaded = try #require(cache.load(vaultID: "abc123"))
        #expect(loaded.fingerprint == key.fingerprint)
        // The key never goes on the command line.
        let secret = key.withRawBytes { Data($0) }.base64EncodedString()
        #expect(fake.calls.allSatisfy { !$0.joined(separator: " ").contains(secret) })
        #expect(fake.calls.contains(["store", "--label=Cairn vault key", "application", "dev.cairn.Cairn", "vault", "abc123"]))
        cache.remove(vaultID: "abc123")
        #expect(cache.load(vaultID: "abc123") == nil)
    }

    // MARK: Restoring secrets

    static func secretsBackup() throws -> (Manifest, SecretsFile, VaultKey) {
        let key = try Vault.create(password: "not a real password").key
        let refs = [SSHKeyScanner.ref(file: "id_test"), CredentialFiles.ref(path: ".config/gh/hosts.yml"),
                    WiFiPasswords.ref(ssid: "Home Network"), WiFiPasswords.ref(ssid: "Already Here"), WiFiPasswords.ref(ssid: "Bad;Name")]
        var file = SecretsFile()
        file.secrets[refs[0]] = try key.seal(Data("-----FAKE KEY-----\n".utf8), ref: refs[0])
        file.secrets[refs[1]] = try key.seal(Data("fake-token".utf8), ref: refs[1])
        file.secrets[refs[2]] = try key.seal(Data("not-a-real-wifi-pw".utf8), ref: refs[2])
        file.secrets[refs[3]] = try key.seal(Data("whatever1".utf8), ref: refs[3])
        file.secrets[refs[4]] = try key.seal(Data("whatever1".utf8), ref: refs[4])
        let types = ["ssh", "token", "wifi", "wifi", "wifi"]
        let m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Date(timeIntervalSince1970: 0),
                         sensitive: zip(types, refs).map { SensitiveRef(type: $0, ref: $1, include: true) }
                            + [SensitiveRef(type: "ssh", ref: SSHKeyScanner.ref(file: "not_saved"), include: true)])
        return (m, file, key)
    }

    @Test func secretsComeBackOnlyWithTheVaultAndNeverReplaceAFile() throws {
        let (m, file, key) = try Self.secretsBackup()
        let home = try Self.temp()
        defer { try? FileManager.default.removeItem(at: home) }
        var privileged: [([String], String?)] = []
        func step() -> LinuxSecretsRestore {
            LinuxSecretsRestore(manifest: m, secrets: file, home: home.path, savedNetworks: { ["Already Here"] },
                                privileged: { args, input in privileged.append((args, input.map { String(decoding: $0, as: UTF8.self) })); return 0 },
                                makePublicKey: { _ in true })
        }
        var lines: [String] = []
        step().run(apply: false, key: nil) { lines.append($0) }
        #expect(lines.first == "Secrets (6)")
        #expect(lines.contains("  skipped ~/.ssh/id_test: unlock the vault to restore it"))
        #expect(lines.contains("  Wi-Fi network Already Here is already saved"))
        #expect(lines.contains("  skipped not_saved: it wasn't saved in the backup"))

        lines = []
        step().run(apply: false, key: key) { lines.append($0) }
        #expect(lines.contains("  would add ~/.ssh/id_test"))
        #expect(lines.contains("  would add ~/.config/gh/hosts.yml"))
        #expect(lines.contains("  would add Wi-Fi network Home Network"))
        #expect(lines.contains { $0.hasPrefix("  skipped Wi-Fi network Bad;Name: join it by hand") })
        #expect(privileged.isEmpty)

        lines = []
        let result = step().run(apply: true, key: key) { lines.append($0) }
        #expect(result.done.sorted() == ["Wi-Fi network Home Network", "id_test", "~/.config/gh/hosts.yml"])
        let keyPath = home.appendingPathComponent(".ssh/id_test").path
        #expect(FileManager.default.contents(atPath: keyPath) == Data("-----FAKE KEY-----\n".utf8))
        #expect((try FileManager.default.attributesOfItem(atPath: keyPath)[.posixPermissions] as? Int) == 0o600)
        // The Wi-Fi password went in on stdin, never on the command line.
        #expect(privileged.count == 2)
        #expect(privileged[0].0.prefix(7) == ["install", "-m", "600", "-o", "root", "-g", "root"])
        #expect(privileged[0].1?.contains("psk=not-a-real-wifi-pw") == true)
        #expect(privileged.allSatisfy { !$0.0.joined(separator: " ").contains("not-a-real-wifi-pw") })
        #expect(privileged[1].0 == ["nmcli", "connection", "load", privileged[0].0.last!])

        // A second run finds them there; a different file of the same name is left alone.
        try Data("someone else's key".utf8).write(to: home.appendingPathComponent(".config/gh/hosts.yml"))
        lines = []
        step().run(apply: true, key: key) { lines.append($0) }
        #expect(lines.contains("  ~/.ssh/id_test is already there"))
        #expect(lines.contains("  skipped ~/.config/gh/hosts.yml: yours differs from the backup, so left alone"))
        #expect(try String(contentsOf: home.appendingPathComponent(".config/gh/hosts.yml"), encoding: .utf8) == "someone else's key")
    }

    @Test func secretLinesReadWellInTheRestoreWindow() {
        let r = KitReport.parse("Secrets (2)\n  would add Wi-Fi network Home\n  ~/.ssh/id_test is already there\nDry run: nothing changed.")
        #expect(r.sections.first?.title == "Secrets")
        #expect(r.sections.first?.items.first?.detail == "Will add")
        #expect(r.sections.first?.items.first?.title == "Wi-Fi network Home")
        #expect(r.sections.first?.items.last?.status == .already)
        #expect(KitReport.parse("Software sources (1)\n  would add brave (https://x.example.com/apt)").sections[0].items[0].detail == "Will add this software source")
    }
}
