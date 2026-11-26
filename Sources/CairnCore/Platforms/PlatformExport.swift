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
    /// A config file carried in the kit's `dotfiles` folder.
    public struct KitDotfile: Equatable, Sendable {
        /// File name in the kit: `gitconfig`, `ssh-config`.
        public var name: String
        /// Where it goes, below the home folder: `.gitconfig`, `.ssh/config`.
        public var target: String
        public var kind: DotfileItem.Kind
        public var text: String
        /// The script puts it in place (git and SSH config). Shell config is
        /// only there to read: it was written for macOS.
        public var installs: Bool
        /// macOS-only lines commented out, and secret-looking lines left out of the backup.
        public var commented: Int
        public var redacted: Int
    }

    public var registry: [RegistryWrite] = []
    public var gsettings: [GSettingsWrite] = []

    /// No known package for this platform.
    public var unmapped: [String] = []
    /// Linux: how to get a package apt or dnf doesn't have, by Homebrew name.
    public var hints: [String: String] = [:]
    public var macOnly: [String] = []
    /// Left out on purpose, with why: `libreoffice` → "you use Microsoft Office, ...".
    public struct Skipped: Equatable, Sendable {
        public var label: String
        public var reason: String
    }
    public var redundant: [Skipped] = []
    public var appStore: [String] = []
    public var shares: [ShareItem] = []
    public var dotfiles: [KitDotfile] = []
    /// Included settings with no equivalent on the target.
    public var settingsLeft = 0
    public var hasLayout = false
    /// Windows: Start menu names to pin to the taskbar, in the Dock's order.
    public var taskbar: [String] = []
    public var secrets = 0

    public var packageCount: Int {
        target == .windows ? winget.count : Set((apt + dnf + flatpak).map(\.label)).count
    }
    public var settingCount: Int { target == .windows ? registry.count : gsettings.count }

    public static func make(_ m: Manifest, for target: TargetPlatform) -> PlatformExport {
        var e = PlatformExport(target: target, device: m.device, backedUp: m.created)
        for p in m.packages where p.include {
            // A tap is only where Homebrew finds packages; its packages are listed on their own.
            if p.kind == .tap { continue }
            let label = p.resolvers["brew"] ?? p.id
            if PackageCatalog.isMacOnly(p) { e.macOnly.append(label); continue }
            if let why = PackageCatalog.redundant(p, in: m, for: target) { e.redundant.append(Skipped(label: label, reason: why)); continue }
            let n = PackageCatalog.names(for: p)
            if target == .linux, let h = n.linuxHint, n.apt == nil || n.dnf == nil { e.hints[label] = h }
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
        for d in m.dotfiles where d.include && Dotfiles.isKnown(d.path) {
            let installs = d.kind != .shell
            let p = installs ? Dotfiles.portable(d, windows: target == .windows) : (text: d.content, commented: 0)
            e.dotfiles.append(KitDotfile(name: Dotfiles.kitName(d.path), target: d.relativePath, kind: d.kind,
                                         text: p.text, installs: installs, commented: p.commented, redacted: d.redacted))
        }
        e.hasLayout = m.layout.dock?.include == true || m.layout.displays?.include == true
            || m.layout.wallpaper?.include == true
        if target == .windows, let dock = m.layout.dock, dock.include {
            e.taskbar = TaskbarPins.windows(dock: dock.apps, usesOffice: PackageCatalog.usesMicrosoftOffice(m))
        }
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

    /// File name → contents. Config files are in a `dotfiles` folder.
    public func files() -> [String: String] {
        var out: [String: String]
        switch target {
        case .windows:
            // Windows PowerShell 5.1 reads a script without a byte order mark as the
            // local code page, which garbles anything that isn't plain ASCII.
            out = ["setup.ps1": "\u{FEFF}" + powershell(), "winget.json": wingetJSON(), "CHECKLIST.md": checklist()]
        case .linux:
            out = ["setup.sh": bash(), "CHECKLIST.md": checklist()]
        }
        for d in dotfiles { out["dotfiles/" + d.name] = d.text }
        return out
    }

    /// Writes the kit into a new folder inside `parent` and returns that folder.
    @discardableResult
    public func write(into parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files() {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        let installs = dotfiles.filter(\.installs).count
        if installs > 0 { parts.append("\(installs) config file\(installs == 1 ? "" : "s")") }
        let byHand = unmapped.count + appStore.count + shares.count + dotfiles.filter { !$0.installs }.count
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
        $notFound = @()
        $reboot = $false
        $signOut = $false

        """
        s += "$packages = [ordered]@{\n"
        for p in winget { s += "    \(ps(p.id)) = \(ps(p.label))\n" }
        s += "}\n"
        s += """

        $haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
        if (-not $haveWinget) {
            Write-Host 'winget is missing: install App Installer from the Microsoft Store, then run this again.'
            if ($Apply) { exit 1 }
        }
        Write-Host "Packages ($($packages.Count))"
        foreach ($p in $packages.GetEnumerator()) {
            if ($haveWinget) {
                winget list --id $p.Key --exact --accept-source-agreements *> $null
                if ($LASTEXITCODE -eq 0) { Write-Host "  $($p.Value) is already installed"; continue }
            }
            if ($Apply) {
                Write-Host "  installing $($p.Value) ($($p.Key))"
                winget install --id $p.Key --exact --source winget --accept-package-agreements --accept-source-agreements
                $code = $LASTEXITCODE
                # Already installed, or nothing newer: done. Needs a restart to finish: done, say so at the end.
                if ($code -eq -1978334967 -or $code -eq -1978334966) { $reboot = $true }
                elseif ($code -ne 0 -and $code -ne -1978335189 -and $code -ne -1978335135) { $failed += $p.Value }
            } elseif ($haveWinget) {
                winget show --id $p.Key --exact --source winget --accept-source-agreements *> $null
                if ($LASTEXITCODE -eq 0) { Write-Host "  would install $($p.Value) ($($p.Key))" }
                else { Write-Host "  can't find $($p.Value) ($($p.Key)) in winget"; $notFound += $p.Value }
            } else {
                Write-Host "  would install $($p.Value) ($($p.Key))"
            }
        }

        """
        s += "$settings = @(\n"
        s += registry.map {
            "    @{ Path = \(ps("HKCU:\\" + $0.path)); Name = \(ps($0.name)); Value = \($0.dword); "
                + "Label = \(ps($0.label.isEmpty ? $0.name : $0.label)); Explorer = $\($0.restartsExplorer ? "true" : "false") }"
        }.joined(separator: ",\n")
        s += (registry.isEmpty ? "" : "\n") + ")\n"
        s += """
        $restartExplorer = $false
        if ($settings.Count -gt 0) { Write-Host "Settings ($($settings.Count))" }
        foreach ($s in $settings) {
            $now = (Get-ItemProperty -Path $s.Path -Name $s.Name -ErrorAction SilentlyContinue).($s.Name)
            if ($null -ne $now -and $now -eq $s.Value) { Write-Host "  $($s.Label): already set"; continue }
            if ($Apply) {
                if (-not (Test-Path $s.Path)) { New-Item -Path $s.Path -Force | Out-Null }
                Set-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -Type DWord
                if ($?) { Write-Host "  set: $($s.Label)"; if ($s.Explorer) { $restartExplorer = $true } }
                else { $failed += $s.Label }
            } else {
                Write-Host "  would set: $($s.Label)"
            }
        }
        if ($restartExplorer) {
            Write-Host '  restarting File Explorer so the change shows'
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        }

        \(powershellTaskbar())\(powershellDotfiles())
        Write-Host ''
        if ($notFound.Count -gt 0) { Write-Host "winget doesn't know: $($notFound -join ', '). Look for them with: winget search <name>" }
        if (-not $Apply) { Write-Host 'Dry run: nothing changed. Run again with -Apply to make these changes.' }
        else {
            if ($failed.Count -gt 0) { Write-Host "Didn't finish: $($failed -join ', ')" }
            if ($reboot) { Write-Host 'Restart Windows to finish installing.' }
            elseif ($signOut) { Write-Host 'Sign out of Windows and back in to see your taskbar.' }
        }
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
        # The command each app has when it came another way (a snap, the distro).
        FLATPAK_CMD=(\(flatpak.map { sh(PackageCatalog.command(forFlatpak: $0.id)) }.joined(separator: " ")))

        missing=()
        # Already there, or can the package manager get it?
        installed() { # manager, package
          if [ "$1" = apt ]; then dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q 'ok installed'
          else rpm -q "$2" >/dev/null 2>&1; fi
        }
        available() { # manager, package
          if [ "$1" = apt ]; then apt-cache policy "$2" 2>/dev/null | grep -q 'Candidate: [^(]'
          else dnf -q info "$2" >/dev/null 2>&1; fi
        }

        install_with() { # manager, packages...
          local manager=$1; shift
          [ $# -gt 0 ] || return 0
          echo "Packages from $manager ($#)"
          # Quiet: one line per package. Errors still show (they go to stderr).
          [ $APPLY = 1 ] && [ "$manager" = apt ] && sudo apt-get update -qq >/dev/null
          for p in "$@"; do
            if installed "$manager" "$p"; then echo "  $p is already installed"; continue; fi
            if ! available "$manager" "$p"; then echo "  $p isn't in $manager here"; missing+=("$p"); continue; fi
            if [ $APPLY = 1 ]; then
              echo "  installing $p"
              if [ "$manager" = apt ]; then sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null || failed+=("$p")
              else sudo dnf install -y -q "$p" >/dev/null || failed+=("$p"); fi
            else
              echo "  would install $p"
            fi
          done
        }

        if command -v apt-get >/dev/null 2>&1; then
          install_with apt "${APT[@]}"
        \(notIn("apt", onlyDNF))\
        elif command -v dnf >/dev/null 2>&1; then
          install_with dnf "${DNF[@]}"
        \(notIn("dnf", onlyAPT))\
        else
          echo "Neither apt-get nor dnf found: install these with your package manager: ${APT[*]}"
        fi

        newflatpak=0
        if [ ${#FLATPAK[@]} -gt 0 ]; then
          echo "Apps from Flathub (${#FLATPAK[@]})"
          if ! command -v flatpak >/dev/null 2>&1; then
            if ! command -v apt-get >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1; then
              echo "  flatpak isn't installed: see https://flathub.org/setup, then run this again."
              FLATPAK=()
            elif [ $APPLY = 1 ]; then
              echo "  installing flatpak first"
              if command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y flatpak; else sudo dnf install -y flatpak; fi
              command -v flatpak >/dev/null 2>&1 || { failed+=(flatpak); FLATPAK=(); }
              newflatpak=1
            else
              echo "  would install flatpak first (this system doesn't have it yet)"
            fi
          fi
          [ $APPLY = 1 ] && [ ${#FLATPAK[@]} -gt 0 ] && flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
          for i in "${!FLATPAK[@]}"; do
            a=${FLATPAK[$i]} c=${FLATPAK_CMD[$i]}
            if command -v flatpak >/dev/null 2>&1 && flatpak info "$a" >/dev/null 2>&1; then echo "  $a is already installed"
            elif command -v "$c" >/dev/null 2>&1 || { command -v snap >/dev/null 2>&1 && snap list "$c" >/dev/null 2>&1; }; then
              echo "  $c is already installed (not from Flathub), so skipping $a"
            elif [ $APPLY = 1 ]; then echo "  installing $a"; flatpak install --user -y --noninteractive flathub "$a" || failed+=("$a")
            else echo "  would install $a"; fi
          done
        fi

        set_setting() { # schema, key, value
          local now
          if ! now=$(gsettings get "$1" "$2" 2>/dev/null); then echo "  skipped $2 (not on this desktop)"; return; fi
          if [ "$now" = "$3" ]; then echo "  $2 is already $3"; return; fi
          if [ "$(gsettings writable "$1" "$2" 2>/dev/null)" != true ]; then echo "  skipped $2 (locked on this system)"; return; fi
          if [ $APPLY = 1 ]; then echo "  changing $2 from $now to $3"; gsettings set "$1" "$2" "$3" || failed+=("$2")
          else echo "  would change $2 from $now to $3"; fi
        }

        """
        if !gsettings.isEmpty {
            s += "if command -v gsettings >/dev/null 2>&1; then\n"
            s += "  echo \"Settings (\(gsettings.count))\"\n"
            for g in gsettings { s += "  set_setting \(sh(g.schema)) \(sh(g.key)) \(sh(g.value))\n" }
            s += "else\n  echo \"Settings skipped: they're for GNOME, and gsettings isn't here.\"\nfi\n"
        }
        s += bashDotfiles()
        s += """

        echo
        [ ${#missing[@]} -gt 0 ] && echo "Not available here, install another way: ${missing[*]}"
        if [ $APPLY = 0 ]; then echo "Dry run: nothing changed. Run again with --apply to make these changes."
        elif [ ${#failed[@]} -gt 0 ]; then echo "Didn't work: ${failed[*]}"; fi
        [ $newflatpak = 1 ] && echo "Log out and back in so the new Flathub apps show up in your app list."
        echo "See CHECKLIST.md for what to do by hand."

        """
        return s
    }

    /// Script lines for packages the other package manager has but this one doesn't.
    func notIn(_ manager: String, _ labels: [String]) -> String {
        labels.map { label in
            let how = hints[label].map { " (try: \($0))" } ?? ""
            return "  echo \(sh("  \(label) isn't in \(manager) here\(how)"))\n  missing+=(\(sh(label)))\n"
        }.joined()
    }

    // MARK: Config files

    var installedDotfiles: [KitDotfile] { dotfiles.filter(\.installs) }

    func powershellDotfiles() -> String {
        let files = installedDotfiles
        guard !files.isEmpty else { return "" }
        var s = "$dotfiles = @(\n"
        s += files.map {
            "    @{ File = \(ps($0.name)); Target = \(ps($0.target.replacingOccurrences(of: "/", with: "\\"))); "
                + "KeepHosts = $\($0.kind == .ssh ? "true" : "false") }"
        }.joined(separator: ",\n")
        s += "\n)\n"
        s += """
        # Host blocks in the PC's SSH config that the kit's copy doesn't have: kept, added at the end.
        function Get-OnlyHereHosts([string[]]$old, [string[]]$new) {
            $have = @{}
            foreach ($l in $new) { if ($l -match '^\\s*Host\\s+(.+?)\\s*$') { $have[$Matches[1]] = $true } }
            $out = @(); $keep = $false
            foreach ($l in $old) {
                if ($l -match '^\\s*(Host|Match)\\s+(.+?)\\s*$') {
                    $keep = $Matches[1] -eq 'Host' -and -not $have.ContainsKey($Matches[2])
                    if ($keep) { $out += '' }
                }
                if ($keep) { $out += $l }
            }
            ,$out
        }
        # No byte order mark: OpenSSH and git read it as part of the first line.
        $utf8 = New-Object System.Text.UTF8Encoding $false
        Write-Host "Config files ($($dotfiles.Count))"
        foreach ($d in $dotfiles) {
            $src = Join-Path (Join-Path $PSScriptRoot 'dotfiles') $d.File
            $dst = Join-Path $HOME $d.Target
            $text = [IO.File]::ReadAllText($src)
            $extra = @()
            if (Test-Path $dst) {
                $old = [IO.File]::ReadAllText($dst)
                if ($d.KeepHosts) {
                    $extra = Get-OnlyHereHosts ($old -split "`r?`n") ($text -split "`r?`n")
                    if ($extra.Count -gt 0) { $text = $text.TrimEnd() + "`n" + ($extra -join "`n") + "`n" }
                }
                if ($old -ceq $text) { Write-Host "  $($d.Target) already matches"; continue }
            }
            $hosts = @($extra | Where-Object { $_ -match '^\\s*Host\\s' }).Count
            $kept = if ($hosts -gt 0) { " and keep $hosts server entr$(if ($hosts -eq 1) { 'y' } else { 'ies' }) only on this PC" } else { '' }
            if ($Apply) {
                New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                if (Test-Path $dst) { Copy-Item $dst "$dst.before-cairn" -Force; Write-Host "  kept your old $($d.Target) as $($d.Target).before-cairn" }
                try { [IO.File]::WriteAllText($dst, $text, $utf8); Write-Host "  wrote $($d.Target)$kept" }
                catch { $failed += $d.Target }
            } elseif (Test-Path $dst) {
                Write-Host "  would replace $($d.Target)$kept (keeping the old one as $($d.Target).before-cairn)"
            } else {
                Write-Host "  would write $($d.Target)"
            }
        }

        """
        return s
    }

    /// Pins the Dock's apps to the taskbar through Windows' taskbar layout policy (the
    /// supported way: there's no API to pin). PinGeneration lets the user unpin them.
    func powershellTaskbar() -> String {
        guard !taskbar.isEmpty else { return "" }
        var s = "$taskbar = @(" + taskbar.map(ps).joined(separator: ", ") + ")\n"
        s += """
        Write-Host "Taskbar, in your Dock's order ($($taskbar.Count))"
        $startApps = @(Get-StartApps)
        $pins = @(); $absent = @()
        foreach ($n in $taskbar) {
            $a = $startApps | Where-Object { $_.Name -eq $n } | Select-Object -First 1
            if ($a) { $pins += $a } else { $absent += $n }
        }
        if ($pins.Count -gt 0) { Write-Host "  $(if ($Apply) { 'pinning' } else { 'would pin' }): $(($pins | ForEach-Object { $_.Name }) -join ', ')" }
        if ($absent.Count -gt 0) { Write-Host "  not on this PC$(if (-not $Apply) { ' (yet)' }): $($absent -join ', ')" }
        if ($Apply -and $pins.Count -gt 0) {
            $menus = @("$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs", "$env:ProgramData\\Microsoft\\Windows\\Start Menu\\Programs")
            $lines = foreach ($a in $pins) {
                $id = $a.AppID
                if ($id -like '*!*') { '<taskbar:UWA AppUserModelID="' + [Security.SecurityElement]::Escape($id) + '" PinGeneration="1"/>'; continue }
                # Apps known by their file path pin more reliably through their Start menu shortcut.
                $lnk = if ($id -like '*\\*') { Get-ChildItem $menus -Recurse -Filter "$($a.Name).lnk" -ErrorAction SilentlyContinue | Select-Object -First 1 }
                if ($lnk) { '<taskbar:DesktopApp DesktopApplicationLinkPath="' + [Security.SecurityElement]::Escape($lnk.FullName) + '" PinGeneration="1"/>' }
                else { '<taskbar:DesktopApp DesktopApplicationID="' + [Security.SecurityElement]::Escape($id) + '" PinGeneration="1"/>' }
            }
            $xml = @(
                '<?xml version="1.0" encoding="utf-8"?>',
                '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">',
                '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">',
                '    <defaultlayout:TaskbarLayout>',
                '      <taskbar:TaskbarPinList>'
            ) + ($lines | ForEach-Object { '        ' + $_ }) + @(
                '      </taskbar:TaskbarPinList>',
                '    </defaultlayout:TaskbarLayout>',
                '  </CustomTaskbarLayoutCollection>',
                '</LayoutModificationTemplate>'
            )
            $layout = Join-Path $env:LOCALAPPDATA 'Cairn\\taskbar.xml'
            New-Item -ItemType Directory -Force -Path (Split-Path $layout) | Out-Null
            [IO.File]::WriteAllText($layout, ($xml -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
            # The policy key needs administrator rights: Windows asks once.
            $key = 'HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer'
            $q = $layout.Replace("'", "''")
            # Only creates the key if it's missing: New-Item -Force on a key that exists empties it.
            $cmd = "`$ErrorActionPreference = 'Stop'; if (-not (Test-Path '$key')) { New-Item -Path '$key' -Force | Out-Null }; " +
                "New-ItemProperty -Path '$key' -Name StartLayoutFile -Value '$q' -PropertyType ExpandString -Force | Out-Null; " +
                "New-ItemProperty -Path '$key' -Name LockedStartLayout -Value 1 -PropertyType DWord -Force | Out-Null"
            try { & ([scriptblock]::Create($cmd)) } catch {
                Write-Host '  Windows will ask for permission to set the taskbar layout'
                $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
                Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $enc"
            }
            if ((Get-ItemProperty -Path $key -Name StartLayoutFile -ErrorAction SilentlyContinue).StartLayoutFile -eq $layout) { $signOut = $true }
            else { $failed += 'taskbar' }
        }

        """
        return s
    }

    func bashDotfiles() -> String {
        let files = installedDotfiles
        guard !files.isEmpty else { return "" }
        var s = """

        KIT="$(cd "$(dirname "$0")" && pwd)"
        put_config() { # kit file, path below $HOME, mode
          local src="$KIT/dotfiles/$1" dst="$HOME/$2"
          if [ -L "$dst" ]; then echo "  skipped $2: it's a link (a dotfiles tool may manage it)"; return; fi
          if [ -f "$dst" ] && cmp -s "$src" "$dst"; then echo "  $2 already matches"; return; fi
          if [ $APPLY = 1 ]; then
            if [ "$3" = 600 ]; then mkdir -p -m 700 "$(dirname "$dst")"; else mkdir -p "$(dirname "$dst")"; fi
            if [ -e "$dst" ]; then cp -p "$dst" "$dst.before-cairn" && echo "  kept your old $2 as $2.before-cairn"; fi
            if install -m "$3" "$src" "$dst"; then echo "  wrote $2"; else failed+=("$2"); fi
          elif [ -e "$dst" ]; then echo "  would replace $2 (keeping the old one as $2.before-cairn)"
          else echo "  would write $2"; fi
        }

        """
        s += "echo \"Config files (\(files.count))\"\n"
        for d in files { s += "put_config \(sh(d.name)) \(sh(d.target)) \(d.kind == .ssh ? "600" : "644")\n" }
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
            s += "That only lists what it would do. Add `-Apply` to do it (this also accepts the packages' license terms for you). Or install just the packages with `winget import -i winget.json`.\n\n"
            if !taskbar.isEmpty {
                s += "### Taskbar\n\n"
                s += "The script pins your Dock's apps to the taskbar in the same order, File Explorer first, in place of what's pinned now. "
                s += "Apps that aren't installed yet are skipped: run the script again once they are. Windows asks for permission once, and the new taskbar shows after you sign out and back in. "
                s += "You can still unpin apps yourself. To hand the taskbar back to Windows, open Registry Editor, go to "
                s += "`HKEY_CURRENT_USER\\Software\\Policies\\Microsoft\\Windows\\Explorer` and delete `StartLayoutFile` and `LockedStartLayout`.\n\n"
            }
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
            byHand += unmapped.sorted().map { label in
                "- [ ] \(Self.oneLine(label))" + (hints[label].map { ": try \(Self.oneLine($0))" } ?? "")
            }.joined(separator: "\n") + "\n\n"
        }
        if target == .linux {
            let onlyDNF = Set(dnf.map(\.label)).subtracting(apt.map(\.label)).sorted()
            let onlyAPT = Set(apt.map(\.label)).subtracting(dnf.map(\.label)).sorted()
            if !onlyDNF.isEmpty || !onlyAPT.isEmpty {
                byHand += "### Not in every distro (\(onlyDNF.count + onlyAPT.count))\n\nThe script installs these only where the package manager has them.\n\n"
                func line(_ label: String, _ missingFrom: String) -> String {
                    "- [ ] \(Self.oneLine(label)): not in \(missingFrom)" + (hints[label].map { ". Try `\(Self.oneLine($0))`" } ?? "")
                }
                byHand += (onlyDNF.map { line($0, "apt (Debian, Ubuntu)") } + onlyAPT.map { line($0, "dnf (Fedora)") })
                    .joined(separator: "\n") + "\n\n"
            }
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
        let shells = dotfiles.filter { !$0.installs }
        if !shells.isEmpty {
            byHand += "### Shell config (\(shells.count))\n\n"
            byHand += target == .windows
                ? "These were written for zsh or bash on the Mac, so the script doesn't install them. They're in the `dotfiles` folder: copy any aliases or settings you want into your PowerShell profile (or into WSL).\n\n"
                : "These were written for the Mac (Homebrew paths, macOS commands), so the script doesn't install them. They're in the `dotfiles` folder: merge what you want into yours.\n\n"
            byHand += shells.map { "- [ ] `\($0.name)` → `~/\(Self.oneLine($0.target))`" }.joined(separator: "\n") + "\n\n"
        }
        let commented = dotfiles.reduce(0) { $0 + $1.commented }
        if commented > 0 {
            byHand += "### macOS-only config lines (\(commented))\n\n"
            byHand += "Lines in your git or SSH config that only work on a Mac (Keychain, Homebrew or /Applications paths) are commented out in the kit's copy. Look for `# cairn: macOS only` and set them up for \(target.title).\n\n"
        }
        let redacted = dotfiles.reduce(0) { $0 + $1.redacted }
        if redacted > 0 {
            byHand += "### Left out of the backup (\(redacted))\n\n"
            byHand += "Lines that looked like secrets (tokens, passwords) were never backed up. Look for `# cairn: removed` and add them back yourself.\n\n"
        }
        if !byHand.isEmpty { s += "## Do by hand\n\n" + byHand }

        var left: [String] = []
        if !macOnly.isEmpty { left.append("\(macOnly.count) Mac-only package\(macOnly.count == 1 ? "" : "s"): \(macOnly.sorted().map(Self.oneLine).joined(separator: ", "))") }
        for r in redundant.sorted(by: { $0.label < $1.label }) {
            left.append("\(Self.oneLine(r.label)): \(r.reason)")
        }
        if settingsLeft > 0 { left.append("\(settingsLeft) macOS setting\(settingsLeft == 1 ? "" : "s") with no \(target.title) equivalent") }
        if hasLayout { left.append(taskbar.isEmpty ? "The Dock, display arrangement and wallpaper" : "The display arrangement and wallpaper") }
        if secrets > 0 { left.append("\(secrets) secret\(secrets == 1 ? "" : "s") (Wi-Fi, SSH keys, passwords): they stay encrypted in your backup and are never written to a plain file") }
        if !left.isEmpty {
            s += "## Not carried over\n\n" + left.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return s
    }

    // MARK: - Helpers

    /// PowerShell single-quoted string. PowerShell also ends a single-quoted string at
    /// curly single quotes (as in a Mac name like `Sam’s Mac`), so those are doubled too.
    func ps(_ s: String) -> String {
        var out = "'"
        for c in Self.oneLine(s) {
            if "'\u{2018}\u{2019}\u{201A}\u{201B}".contains(c) { out.append(c) }
            out.append(c)
        }
        return out + "'"
    }
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
