import Foundation

/// What a package is called by other platforms' package managers.
public struct PackageNames: Equatable, Sendable {
    public var winget: String?
    public var apt: String?
    public var dnf: String?
    public var flatpak: String?
    /// How to get it on Linux when apt or dnf doesn't have it, e.g. `pipx install uv`.
    public var linuxHint: String?

    public init(winget: String? = nil, apt: String? = nil, dnf: String? = nil, flatpak: String? = nil,
                linuxHint: String? = nil) {
        self.winget = winget
        self.apt = apt
        self.dnf = dnf
        self.flatpak = flatpak
        self.linuxHint = linuxHint
    }

    public var isEmpty: Bool { winget == nil && apt == nil && dnf == nil && flatpak == nil }
}

/// Homebrew names mapped to winget, apt, dnf and Flathub ids.
///
/// Checked against winget-pkgs, Flathub, Ubuntu and Fedora with
/// `scripts/check-catalog.py`; run it after editing.
///
/// Looked up when exporting rather than written into backups, so improving the
/// table never makes old snapshots look changed. A manifest's own `resolvers`
/// (say, edited by hand) win over this table.
public enum PackageCatalog {
    /// Names for a package: the manifest's own resolvers first, then the table.
    public static func names(for p: PackageItem) -> PackageNames {
        var n = lookup(p) ?? PackageNames()
        if let v = p.resolvers["winget"] { n.winget = v }
        if let v = p.resolvers["apt"] { n.apt = v }
        if let v = p.resolvers["dnf"] { n.dnf = v }
        if let v = p.resolvers["flatpak"] { n.flatpak = v }
        return n
    }

    /// Made for macOS only, so there's nothing to install elsewhere.
    public static func isMacOnly(_ p: PackageItem) -> Bool {
        p.kind == .tap || macOnly.contains(p.id)
    }

    static func lookup(_ p: PackageItem) -> PackageNames? {
        switch p.kind {
        case .formula: return formulae[p.id] ?? formulae[unversioned(p.id)]
        case .cask: return casks[p.id]
        case .tap: return nil
        }
    }

    /// `node@22` → `node`, `python@3.13` stays (it has its own entry or none).
    static func unversioned(_ id: String) -> String {
        id.split(separator: "@").first.map(String.init) ?? id
    }

    /// The command a Flathub app usually has when installed another way (Ubuntu's
    /// Firefox snap, a distro LibreOffice), so `setup.sh` doesn't add a second copy.
    /// Mostly the id's last part, lowercased.
    public static func command(forFlatpak id: String) -> String {
        if let c = flatpakCommands[id] { return c }
        return id.split(separator: ".").last.map { $0.lowercased() } ?? id
    }

    static let flatpakCommands: [String: String] = [
        "com.bambulab.BambuStudio": "bambu-studio", "com.bitwarden.desktop": "bitwarden",
        "com.brave.Browser": "brave-browser", "com.google.AndroidStudio": "android-studio",
        "com.google.Chrome": "google-chrome", "com.jgraph.drawio.desktop": "drawio",
        "com.mojang.Minecraft": "minecraft-launcher", "com.obsproject.Studio": "obs",
        "com.prusa3d.PrusaSlicer": "prusa-slicer", "com.spotify.Client": "spotify",
        "com.sublimetext.three": "subl", "com.transmissionbt.Transmission": "transmission-gtk",
        "com.visualstudio.code": "code", "fr.handbrake.ghb": "ghb", "org.signal.Signal": "signal-desktop",
        "org.telegram.desktop": "telegram-desktop", "com.github.qarmin.czkawka": "czkawka_gui",
    ]

    static let macOnly: Set<String> = [
        // Formulae
        "mas", "displayplacer", "sleepwatcher", "media-control", "dockutil", "duti", "blueutil",
        "switchaudio-osx", "terminal-notifier", "trash", "tart", "xcodes", "cocoapods",
        // Casks
        "alfred", "raycast", "rectangle", "magnet", "iterm2", "appcleaner", "macfuse", "orbstack",
        "linearmouse", "dockdoor", "swift-quit", "pika", "latest", "boring-notch", "thaw",
        "karabiner-elements", "bartender", "hiddenbar", "jordanbaird-ice", "stats", "the-unarchiver",
        "keka", "iina", "utm", "parallels", "bettertouchtool", "alt-tab", "aldente", "monitorcontrol",
        "betterdisplay", "lunar", "macusb", "wch-ch34x-usb-serial-driver", "xcodes-app", "sf-symbols",
        "hammerspoon", "amphetamine", "keepingyouawake", "maccy", "shottr", "cleanshot", "istat-menus",
        "mos", "scroll-reverser", "unnaturalscrollwheels", "tiles", "whatcable", "ghostty",
    ]

    /// Command-line tools, by Homebrew formula name.
    static let formulae: [String: PackageNames] = [
        "7zip": .init(winget: "7zip.7zip", apt: "7zip", dnf: "7zip"),
        "p7zip": .init(winget: "7zip.7zip", apt: "7zip", dnf: "7zip"),
        "android-platform-tools": .init(winget: "Google.PlatformTools", apt: "android-sdk-platform-tools", dnf: "android-tools"),
        "awscli": .init(winget: "Amazon.AWSCLI", apt: "awscli", dnf: "awscli2"),
        "bat": .init(winget: "sharkdp.bat", apt: "bat", dnf: "bat"),
        "btop": .init(apt: "btop", dnf: "btop"),
        "cmake": .init(winget: "Kitware.CMake", apt: "cmake", dnf: "cmake"),
        "curl": .init(winget: "cURL.cURL", apt: "curl", dnf: "curl"),
        "czkawka": .init(flatpak: "com.github.qarmin.czkawka"),
        "deno": .init(winget: "DenoLand.Deno"),
        "exiftool": .init(winget: "OliverBetz.ExifTool", apt: "libimage-exiftool-perl", dnf: "perl-Image-ExifTool"),
        "fastfetch": .init(winget: "Fastfetch-cli.Fastfetch", apt: "fastfetch", dnf: "fastfetch"),
        "fd": .init(winget: "sharkdp.fd", apt: "fd-find", dnf: "fd-find"),
        "ffmpeg": .init(winget: "Gyan.FFmpeg", apt: "ffmpeg", dnf: "ffmpeg-free"),
        "fzf": .init(winget: "junegunn.fzf", apt: "fzf", dnf: "fzf"),
        "gh": .init(winget: "GitHub.cli", apt: "gh", dnf: "gh"),
        "git": .init(winget: "Git.Git", apt: "git", dnf: "git"),
        "git-lfs": .init(winget: "GitHub.GitLFS", apt: "git-lfs", dnf: "git-lfs"),
        "gnupg": .init(winget: "GnuPG.GnuPG", apt: "gnupg", dnf: "gnupg2"),
        "go": .init(winget: "GoLang.Go", apt: "golang-go", dnf: "golang"),
        "helm": .init(winget: "Helm.Helm", dnf: "helm", linuxHint: "sudo snap install helm --classic"),
        "htop": .init(apt: "htop", dnf: "htop"),
        "hugo": .init(apt: "hugo", dnf: "hugo"),
        "ideviceinstaller": .init(apt: "ideviceinstaller", dnf: "ideviceinstaller"),
        "imagemagick": .init(winget: "ImageMagick.ImageMagick", apt: "imagemagick", dnf: "ImageMagick"),
        "iperf3": .init(apt: "iperf3", dnf: "iperf3"),
        "jq": .init(winget: "jqlang.jq", apt: "jq", dnf: "jq"),
        "kubernetes-cli": .init(winget: "Kubernetes.kubectl", linuxHint: "sudo snap install kubectl --classic"),
        "lazygit": .init(winget: "JesseDuffield.lazygit"),
        "libaacs": .init(apt: "libaacs0"),
        "libavif": .init(apt: "libavif-bin", dnf: "libavif-tools"),
        "libraw": .init(apt: "libraw-bin", dnf: "LibRaw"),
        "mkvtoolnix": .init(winget: "MoritzBunkus.MKVToolNix", apt: "mkvtoolnix", dnf: "mkvtoolnix"),
        "neovim": .init(winget: "Neovim.Neovim", apt: "neovim", dnf: "neovim"),
        "nmap": .init(winget: "Insecure.Nmap", apt: "nmap", dnf: "nmap"),
        "nut": .init(apt: "nut", dnf: "nut"),
        "node": .init(winget: "OpenJS.NodeJS.LTS", apt: "nodejs", dnf: "nodejs"),
        "ollama": .init(winget: "Ollama.Ollama", linuxHint: "the installer at ollama.com/download"),
        "pandoc": .init(winget: "JohnMacFarlane.Pandoc", apt: "pandoc", dnf: "pandoc"),
        "pipx": .init(apt: "pipx", dnf: "pipx"),
        "pyenv": .init(apt: "pyenv"),
        "python": .init(winget: "Python.Python.3.13", apt: "python3", dnf: "python3"),
        "python@3.12": .init(winget: "Python.Python.3.12", apt: "python3", dnf: "python3"),
        "python@3.13": .init(winget: "Python.Python.3.13", apt: "python3", dnf: "python3"),
        "python-tk": .init(apt: "python3-tk", dnf: "python3-tkinter"),
        "redis": .init(apt: "redis-server", dnf: "valkey"),
        "ripgrep": .init(winget: "BurntSushi.ripgrep.MSVC", apt: "ripgrep", dnf: "ripgrep"),
        "rustup": .init(winget: "Rustlang.Rustup", apt: "rustup", dnf: "rustup"),
        "scrcpy": .init(winget: "Genymobile.scrcpy", apt: "scrcpy"),
        "sqlite": .init(winget: "SQLite.SQLite", apt: "sqlite3", dnf: "sqlite"),
        "terraform": .init(winget: "Hashicorp.Terraform"),
        "tmux": .init(apt: "tmux", dnf: "tmux"),
        "tree": .init(apt: "tree", dnf: "tree"),
        "uv": .init(winget: "astral-sh.uv", dnf: "uv", linuxHint: "pipx install uv"),
        "vim": .init(winget: "vim.vim", apt: "vim", dnf: "vim-enhanced"),
        "wget": .init(winget: "JernejSimoncic.Wget", apt: "wget", dnf: "wget2-wget"),
        "wireguard-tools": .init(winget: "WireGuard.WireGuard", apt: "wireguard-tools", dnf: "wireguard-tools"),
        "yt-dlp": .init(winget: "yt-dlp.yt-dlp", apt: "yt-dlp", dnf: "yt-dlp"),
        "zsh": .init(apt: "zsh", dnf: "zsh"),
    ]

    /// Apps, by Homebrew cask name. Linux gets them from Flathub where they're there.
    static let casks: [String: PackageNames] = [
        "1password": .init(winget: "AgileBits.1Password"),
        "alacritty": .init(winget: "Alacritty.Alacritty", apt: "alacritty", dnf: "alacritty"),
        "android-platform-tools": .init(winget: "Google.PlatformTools", apt: "android-sdk-platform-tools", dnf: "android-tools"),
        "android-studio": .init(winget: "Google.AndroidStudio", flatpak: "com.google.AndroidStudio"),
        "audacity": .init(winget: "Audacity.Audacity", flatpak: "org.audacityteam.Audacity"),
        "balenaetcher": .init(winget: "Balena.Etcher"),
        "bambu-studio": .init(winget: "Bambulab.Bambustudio", flatpak: "com.bambulab.BambuStudio"),
        "bitwarden": .init(winget: "Bitwarden.Bitwarden", flatpak: "com.bitwarden.desktop"),
        "blender": .init(winget: "BlenderFoundation.Blender", flatpak: "org.blender.Blender"),
        "brave-browser": .init(winget: "Brave.Brave", flatpak: "com.brave.Browser"),
        "cursor": .init(winget: "Anysphere.Cursor"),
        "czkawka": .init(flatpak: "com.github.qarmin.czkawka"),
        "db-browser-for-sqlite": .init(winget: "DBBrowserForSQLite.DBBrowserForSQLite", flatpak: "org.sqlitebrowser.sqlitebrowser"),
        "discord": .init(winget: "Discord.Discord", flatpak: "com.discordapp.Discord"),
        "docker": .init(winget: "Docker.DockerDesktop"),
        "docker-desktop": .init(winget: "Docker.DockerDesktop"),
        "drawio": .init(winget: "JGraph.Draw", flatpak: "com.jgraph.drawio.desktop"),
        "firefox": .init(winget: "Mozilla.Firefox", flatpak: "org.mozilla.firefox"),
        "freecad": .init(winget: "FreeCAD.FreeCAD", flatpak: "org.freecad.FreeCAD"),
        "gimp": .init(winget: "GIMP.GIMP", flatpak: "org.gimp.GIMP"),
        "github": .init(winget: "GitHub.GitHubDesktop"),
        "google-chrome": .init(winget: "Google.Chrome", flatpak: "com.google.Chrome"),
        "handbrake": .init(winget: "HandBrake.HandBrake", flatpak: "fr.handbrake.ghb"),
        "handbrake-app": .init(winget: "HandBrake.HandBrake", flatpak: "fr.handbrake.ghb"),
        "inkscape": .init(winget: "Inkscape.Inkscape", flatpak: "org.inkscape.Inkscape"),
        "jetbrains-toolbox": .init(winget: "JetBrains.Toolbox"),
        "keepassxc": .init(winget: "KeePassXCTeam.KeePassXC", flatpak: "org.keepassxc.KeePassXC"),
        "kicad": .init(winget: "KiCad.KiCad", flatpak: "org.kicad.KiCad"),
        "libreoffice": .init(winget: "TheDocumentFoundation.LibreOffice", flatpak: "org.libreoffice.LibreOffice"),
        "microsoft-teams": .init(winget: "Microsoft.Teams"),
        "minecraft": .init(winget: "Mojang.MinecraftLauncher", flatpak: "com.mojang.Minecraft"),
        "obs": .init(winget: "OBSProject.OBSStudio", flatpak: "com.obsproject.Studio"),
        "obsidian": .init(winget: "Obsidian.Obsidian", flatpak: "md.obsidian.Obsidian"),
        "openscad": .init(winget: "OpenSCAD.OpenSCAD", flatpak: "org.openscad.OpenSCAD"),
        "postman": .init(winget: "Postman.Postman", flatpak: "com.getpostman.Postman"),
        "prusaslicer": .init(winget: "Prusa3D.PrusaSlicer", flatpak: "com.prusa3d.PrusaSlicer"),
        "qbittorrent": .init(winget: "qBittorrent.qBittorrent", flatpak: "org.qbittorrent.qBittorrent"),
        "raspberry-pi-imager": .init(winget: "RaspberryPiFoundation.RaspberryPiImager", flatpak: "org.raspberrypi.rpi-imager"),
        "signal": .init(winget: "OpenWhisperSystems.Signal", flatpak: "org.signal.Signal"),
        "slack": .init(winget: "SlackTechnologies.Slack", flatpak: "com.slack.Slack"),
        "spotify": .init(winget: "Spotify.Spotify", flatpak: "com.spotify.Client"),
        "steam": .init(winget: "Valve.Steam", flatpak: "com.valvesoftware.Steam"),
        "sublime-text": .init(winget: "SublimeHQ.SublimeText.4", flatpak: "com.sublimetext.three"),
        "tailscale": .init(winget: "Tailscale.Tailscale"),
        "tailscale-app": .init(winget: "Tailscale.Tailscale"),
        "telegram": .init(winget: "Telegram.TelegramDesktop", flatpak: "org.telegram.desktop"),
        "telegram-desktop": .init(winget: "Telegram.TelegramDesktop", flatpak: "org.telegram.desktop"),
        "temurin": .init(winget: "EclipseAdoptium.Temurin.21.JDK", apt: "openjdk-21-jdk", dnf: "java-21-openjdk-devel"),
        "thunderbird": .init(winget: "Mozilla.Thunderbird", flatpak: "org.mozilla.Thunderbird"),
        "transmission": .init(winget: "Transmission.Transmission", flatpak: "com.transmissionbt.Transmission"),
        "ultimaker-cura": .init(winget: "Ultimaker.Cura", flatpak: "com.ultimaker.cura"),
        "upscayl": .init(flatpak: "org.upscayl.Upscayl"),
        "veracrypt": .init(winget: "IDRIX.VeraCrypt"),
        "virtualbox": .init(winget: "Oracle.VirtualBox"),
        "visual-studio-code": .init(winget: "Microsoft.VisualStudioCode", flatpak: "com.visualstudio.code"),
        "vlc": .init(winget: "VideoLAN.VLC", flatpak: "org.videolan.VLC"),
        "wezterm": .init(winget: "wez.wezterm", flatpak: "org.wezfurlong.wezterm"),
        "wireshark": .init(winget: "WiresharkFoundation.Wireshark", flatpak: "org.wireshark.Wireshark"),
        "wireshark-app": .init(winget: "WiresharkFoundation.Wireshark", flatpak: "org.wireshark.Wireshark"),
        "zed": .init(winget: "ZedIndustries.Zed", flatpak: "dev.zed.Zed"),
        "zoom": .init(winget: "Zoom.Zoom", flatpak: "us.zoom.Zoom"),
    ]
}
