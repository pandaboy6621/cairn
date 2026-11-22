import Foundation

/// Another OS a backup can set up.
public enum TargetPlatform: String, CaseIterable, Identifiable, Sendable {
    case windows, linux

    public var id: String { rawValue }
    public var title: String { self == .windows ? "Windows" : "Linux" }
}

/// Turns a Mac backup into a setup kit for Windows (winget + registry) or Linux
/// (apt or dnf, Flathub, GNOME settings): a script that is a dry run unless asked
/// to apply, plus a checklist of what has to be done by hand.
///
/// Pure: reads only the manifest, so it works for any backup and needs no Mac APIs.
/// Secrets are never exported; they stay encrypted in the backup.
public struct PlatformExport: Equatable, Sendable {
    public struct Install: Equatable, Sendable {
        /// The id the target's package manager knows.
        public var id: String
        /// The Homebrew name, for messages.
        public var label: String
    }

    public var target: TargetPlatform
    public var device: Device
    public var backedUp: Date

    public var winget: [Install] = []
    public var apt: [Install] = []
    public var dnf: [Install] = []
    public var flatpak: [Install] = []
    public var registry: [RegistryWrite] = []
    public var gsettings: [GSettingsWrite] = []

    /// No known package for this platform.
    public var unmapped: [String] = []
    public var macOnly: [String] = []
    public var appStore: [String] = []
    public var shares: [ShareItem] = []
    /// Included settings with no equivalent on the target.
    public var settingsLeft = 0
    public var hasLayout = false
    public var secrets = 0

    public var packageCount: Int {
        target == .windows ? winget.count : Set((apt + dnf + flatpak).map(\.label)).count
    }
    public var settingCount: Int { target == .windows ? registry.count : gsettings.count }

    public static func make(_ m: Manifest, for target: TargetPlatform) -> PlatformExport {
        var e = PlatformExport(target: target, device: m.device, backedUp: m.created)
        for p in m.packages where p.include {
            let label = p.resolvers["brew"] ?? p.id
            if PackageCatalog.isMacOnly(p) { e.macOnly.append(label); continue }
            let n = PackageCatalog.names(for: p)
            switch target {
            case .windows:
                if let id = valid(n.winget) { e.winget.append(Install(id: id, label: label)) } else { e.unmapped.append(label) }
            case .linux:
                // Apps come from Flathub where they're there; tools from the distro.
                if p.kind == .cask, let id = valid(n.flatpak) {
                    e.flatpak.append(Install(id: id, label: label))
                } else if valid(n.apt) != nil || valid(n.dnf) != nil {
                    if let id = valid(n.apt) { e.apt.append(Install(id: id, label: label)) }
                    if let id = valid(n.dnf) { e.dnf.append(Install(id: id, label: label)) }
                } else if let id = valid(n.flatpak) {
                    e.flatpak.append(Install(id: id, label: label))
                } else {
                    e.unmapped.append(label)
                }
            }
        }
        // `node` and `node@22` can both map to `nodejs`: install it once.
        func unique(_ list: [Install]) -> [Install] {
            var seen = Set<String>()
            return list.filter { seen.insert($0.id).inserted }
        }
        e.winget = unique(e.winget); e.apt = unique(e.apt); e.dnf = unique(e.dnf); e.flatpak = unique(e.flatpak)
        e.appStore = m.apps.filter(\.include).map(\.name)
        for s in m.settings where s.include {
            switch target {
            case .windows:
                let w = PortableSettings.windows(s)
                if w.isEmpty { e.settingsLeft += 1 } else { e.registry += w }
            case .linux:
                let w = PortableSettings.linux(s)
                if w.isEmpty { e.settingsLeft += 1 } else { e.gsettings += w }
            }
        }
        e.shares = m.shares.filter(\.include)
        e.hasLayout = m.layout.dock?.include == true || m.layout.displays?.include == true
            || m.layout.wallpaper?.include == true
        e.secrets = m.sensitive.filter(\.include).count
        return e
    }

    /// Package ids go into scripts, so only plain names are allowed (a hand-edited
    /// manifest can't smuggle in a command).
    static func valid(_ id: String?) -> String? {
        guard let id, let first = id.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              id.count <= 128, id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0)) })
        else { return nil }
        return id
    }

    // MARK: - Files

    /// The kit's folder name, e.g. `Cairn for Windows (studio-mac)`.
    public var folderName: String { "Cairn for \(target.title) (\(Self.fileSafe(device.name)))" }

    /// File name → contents.
    public func files() -> [String: String] {
        switch target {
        case .windows:
            return ["setup.ps1": powershell(), "winget.json": wingetJSON(), "CHECKLIST.md": checklist()]
        case .linux:
            return ["setup.sh": bash(), "CHECKLIST.md": checklist()]
        }
    }

    /// Writes the kit into a new folder inside `parent` and returns that folder.
    @discardableResult
    public func write(into parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files() {
            let url = folder.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if name.hasSuffix(".sh") {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        return folder
    }

    /// One line for the CLI and the app.
    public var summary: String {
        var parts = ["\(packageCount) package\(packageCount == 1 ? "" : "s")"]
        if settingCount > 0 { parts.append("\(settingCount) setting\(settingCount == 1 ? "" : "s")") }
        let byHand = unmapped.count + appStore.count + shares.count
        var s = "\(target.title) setup: " + parts.joined(separator: ", ")
        if byHand > 0 { s += "; \(byHand) to do by hand" }
        return s
    }

    var header: String {
        "Cairn: set up \(target.title) like \(Self.oneLine(device.name)) (backed up \(Self.day(backedUp)))"
    }

    // MARK: Windows

    func powershell() -> String {
        var s = """
        # \(header)
        # Dry run by default: lists what it would do. To make the changes, run in PowerShell:
        #   powershell -ExecutionPolicy Bypass -File .\\setup.ps1 -Apply
        param([switch]$Apply)
        $ErrorActionPreference = 'Continue'
        $failed = @()

        """
        s += "$packages = [ordered]@{\n"
        for p in winget { s += "    \(ps(p.id)) = \(ps(p.label))\n" }
        s += "}\n"
        s += """

        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Host 'winget is missing: install App Installer from the Microsoft Store, then run this again.'
            if ($Apply) { exit 1 }
        }
        Write-Host "Packages ($($packages.Count))"
        foreach ($p in $packages.GetEnumerator()) {
            if ($Apply) {
                Write-Host "  installing $($p.Value) ($($p.Key))"
                winget install --id $p.Key --exact --source winget
                # Already installed (or nothing newer) counts as done.
                if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189 -and $LASTEXITCODE -ne -1978335135) { $failed += $p.Value }
            } else {
                Write-Host "  would install $($p.Value) ($($p.Key))"
            }
        }

        """
        s += "$settings = @(\n"
        s += registry.map { "    @{ Path = \(ps("HKCU:\\" + $0.path)); Name = \(ps($0.name)); Value = \($0.dword) }" }
            .joined(separator: ",\n")
        s += (registry.isEmpty ? "" : "\n") + ")\n"
        s += "$restartExplorer = $\(registry.contains(where: \.restartsExplorer) ? "true" : "false")\n"
        s += """
        if ($settings.Count -gt 0) { Write-Host "Settings ($($settings.Count))" }
        foreach ($s in $settings) {
            if ($Apply) {
                Write-Host "  setting $($s.Name) to $($s.Value)"
                if (-not (Test-Path $s.Path)) { New-Item -Path $s.Path | Out-Null }
                Set-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -Type DWord
            } else {
                Write-Host "  would set $($s.Name) to $($s.Value)"
            }
        }
        if ($Apply -and $restartExplorer -and $settings.Count -gt 0) { Stop-Process -Name explorer -Force }

        Write-Host ''
        if (-not $Apply) { Write-Host 'Dry run: nothing changed. Run again with -Apply to make these changes.' }
        elseif ($failed.Count -gt 0) { Write-Host "Didn't install: $($failed -join ', ')" }
        Write-Host 'See CHECKLIST.md for what to do by hand.'

        """
        return s
    }

    /// For `winget import -i winget.json` (installs everything without the script).
    func wingetJSON() -> String {
        let packages = winget.map { #"          { "PackageIdentifier": "\#($0.id)" }"# }.joined(separator: ",\n")
        return """
        {
          "$schema": "https://aka.ms/winget-packages.schema.2.0.json",
          "CreationDate": "\(Self.iso(backedUp))",
          "Sources": [
            {
              "Packages": [
        \(packages)
              ],
              "SourceDetails": {
                "Argument": "https://cdn.winget.microsoft.com/cache",
                "Identifier": "Microsoft.Winget.Source_8wekyb3d8bbwe",
                "Name": "winget",
                "Type": "Microsoft.PreIndexed.Package"
              }
            }
          ],
          "WinGetVersion": "1.6.0"
        }

        """
    }

    // MARK: Linux

    func bash() -> String {
        let onlyDNF = Set(dnf.map(\.label)).subtracting(apt.map(\.label)).sorted()
        let onlyAPT = Set(apt.map(\.label)).subtracting(dnf.map(\.label)).sorted()
        var s = """
        #!/usr/bin/env bash
        # \(header)
        # Dry run by default: lists what it would do. To make the changes, run:
        #   bash setup.sh --apply
        APPLY=0
        [ "${1:-}" = "--apply" ] && APPLY=1
        failed=()

        APT=(\(apt.map { sh($0.id) }.joined(separator: " ")))
        DNF=(\(dnf.map { sh($0.id) }.joined(separator: " ")))
        FLATPAK=(\(flatpak.map { sh($0.id) }.joined(separator: " ")))

        install_with() { # manager, packages...
          local manager=$1; shift
          [ $# -gt 0 ] || return 0
          echo "Packages from $manager ($#)"
          [ $APPLY = 1 ] && [ "$manager" = apt ] && sudo apt-get update
          for p in "$@"; do
            if [ $APPLY = 1 ]; then
              echo "  installing $p"
              if [ "$manager" = apt ]; then sudo apt-get install -y "$p" || failed+=("$p")
              else sudo dnf install -y "$p" || failed+=("$p"); fi
            else
              echo "  would install $p"
            fi
          done
        }

        if command -v apt-get >/dev/null 2>&1; then
          install_with apt "${APT[@]}"
        \(onlyDNF.isEmpty ? "" : "  echo \(sh("  not in apt, install another way: " + onlyDNF.joined(separator: ", ")))\n")\
        elif command -v dnf >/dev/null 2>&1; then
          install_with dnf "${DNF[@]}"
        \(onlyAPT.isEmpty ? "" : "  echo \(sh("  not in dnf, install another way: " + onlyAPT.joined(separator: ", ")))\n")\
        else
          echo "Neither apt-get nor dnf found: install these with your package manager: ${APT[*]}"
        fi

        if [ ${#FLATPAK[@]} -gt 0 ]; then
          echo "Apps from Flathub (${#FLATPAK[@]})"
          if ! command -v flatpak >/dev/null 2>&1; then
            echo "  flatpak isn't installed: see https://flathub.org/setup, then run this again."
          else
            [ $APPLY = 1 ] && flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
            for a in "${FLATPAK[@]}"; do
              if [ $APPLY = 1 ]; then echo "  installing $a"; flatpak install --user -y flathub "$a" || failed+=("$a")
              else echo "  would install $a"; fi
            done
          fi
        fi

        set_setting() { # schema, key, value
          if ! gsettings writable "$1" "$2" >/dev/null 2>&1; then echo "  skipped $2 (not on this desktop)"; return; fi
          if [ $APPLY = 1 ]; then echo "  setting $2 to $3"; gsettings set "$1" "$2" "$3" || failed+=("$2")
          else echo "  would set $2 to $3"; fi
        }

        """
        if !gsettings.isEmpty {
            s += "if command -v gsettings >/dev/null 2>&1; then\n"
            s += "  echo \"Settings (\(gsettings.count))\"\n"
            for g in gsettings { s += "  set_setting \(sh(g.schema)) \(sh(g.key)) \(sh(g.value))\n" }
            s += "else\n  echo \"Settings skipped: they're for GNOME, and gsettings isn't here.\"\nfi\n"
        }
        s += """

        echo
        if [ $APPLY = 0 ]; then echo "Dry run: nothing changed. Run again with --apply to make these changes."
        elif [ ${#failed[@]} -gt 0 ]; then echo "Didn't install: ${failed[*]}"; fi
        echo "See CHECKLIST.md for what to do by hand."

        """
        return s
    }

    // MARK: Checklist

    func checklist() -> String {
        let name = Self.oneLine(device.name)
        var s = "# Set up \(target.title) like \(name)\n\n"
        s += "Made by Cairn from a backup of \(name) (macOS \(Self.oneLine(device.osVersion))) taken \(Self.day(backedUp)).\n\n"
        s += "## Run the setup script\n\n"
        switch target {
        case .windows:
            s += "Installs \(winget.count) package\(winget.count == 1 ? "" : "s") with winget"
            s += registry.isEmpty ? ".\n\n" : " and sets \(registry.count) setting\(registry.count == 1 ? "" : "s").\n\n"
            s += "In PowerShell, in this folder:\n\n```\npowershell -ExecutionPolicy Bypass -File .\\setup.ps1\n```\n\n"
            s += "That only lists what it would do. Add `-Apply` to do it. Or install just the packages with `winget import -i winget.json`.\n\n"
        case .linux:
            s += "Installs packages with apt (Debian, Ubuntu) or dnf (Fedora), apps from Flathub"
            s += gsettings.isEmpty ? ".\n\n" : ", and sets \(gsettings.count) GNOME setting\(gsettings.count == 1 ? "" : "s").\n\n"
            s += "In a terminal, in this folder:\n\n```\nbash setup.sh\n```\n\n"
            s += "That only lists what it would do. Add `--apply` to do it (it asks for your password for apt or dnf).\n\n"
        }

        var byHand = ""
        if !unmapped.isEmpty {
            let how = target == .windows ? "`winget search <name>`" : "your package manager or flathub.org"
            byHand += "### Find these yourself (\(unmapped.count))\n\nCairn doesn't know their \(target.title) name. Try \(how).\n\n"
            byHand += unmapped.sorted().map { "- [ ] \(Self.oneLine($0))" }.joined(separator: "\n") + "\n\n"
        }
        if !appStore.isEmpty {
            byHand += "### Mac App Store apps (\(appStore.count))\n\nSome have \(target.title) versions on their makers' sites.\n\n"
            byHand += appStore.sorted().map { "- [ ] \(Self.oneLine($0))" }.joined(separator: "\n") + "\n\n"
        }
        if !shares.isEmpty {
            byHand += "### Network shares (\(shares.count))\n\n"
            byHand += target == .windows
                ? "In File Explorer, choose Map network drive and enter the address.\n\n"
                : "In Files, choose Other Locations and enter the address.\n\n"
            byHand += shares.map { share in
                let address = target == .windows ? Self.uncPath(share.url) : share.url
                let user = share.username.map { " (as \(Self.oneLine($0)))" } ?? ""
                return "- [ ] `\(Self.oneLine(address))`\(user)"
            }.joined(separator: "\n") + "\n\n"
        }
        if !byHand.isEmpty { s += "## Do by hand\n\n" + byHand }

        var left: [String] = []
        if !macOnly.isEmpty { left.append("\(macOnly.count) Mac-only package\(macOnly.count == 1 ? "" : "s"): \(macOnly.sorted().map(Self.oneLine).joined(separator: ", "))") }
        if settingsLeft > 0 { left.append("\(settingsLeft) macOS setting\(settingsLeft == 1 ? "" : "s") with no \(target.title) equivalent") }
        if hasLayout { left.append("The Dock, display arrangement and wallpaper") }
        if secrets > 0 { left.append("\(secrets) secret\(secrets == 1 ? "" : "s") (Wi-Fi, SSH keys, passwords): they stay encrypted in your backup and are never written to a plain file") }
        if !left.isEmpty {
            s += "## Not carried over\n\n" + left.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return s
    }

    // MARK: - Helpers

    /// PowerShell single-quoted string.
    func ps(_ s: String) -> String { "'" + Self.oneLine(s).replacingOccurrences(of: "'", with: "''") + "'" }
    /// POSIX shell single-quoted string.
    func sh(_ s: String) -> String { "'" + Self.oneLine(s).replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// No newlines or control characters (names end up in comments and Markdown).
    static func oneLine(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
    }

    static func fileSafe(_ s: String) -> String {
        let cleaned = oneLine(s).map { "/:\\".contains($0) ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces).isEmpty ? "Mac" : String(cleaned)
    }

    /// `smb://server/share/dir` → `\\server\share\dir`.
    static func uncPath(_ url: String) -> String {
        guard let r = url.range(of: "://") else { return url }
        return #"\\"# + url[r.upperBound...].replacingOccurrences(of: "/", with: #"\"#)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }
}
