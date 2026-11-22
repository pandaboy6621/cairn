# Cairn

Cairn backs up, restores, and syncs a Mac's *setup* (not its files) so a new machine can be configured in minutes. Think macprefs + Homebrew Bundle + geerlingguy/mac-dev-playbook, with a GUI, snapshots, NAS storage, and a universal manifest that can later target Windows (winget) and Linux (apt/dnf/flatpak).

Name: Cairn (a stack of stones marking the trail). Icon: three stacked teal stones on an indigo rounded square, small gold dot above.

## Non-goals
- Never back up user files (Documents, Photos, etc.). This is not Time Machine.
- No App Store distribution. Cairn runs `brew`, `defaults`, `security`, so it ships notarized outside the store.
- No cloud service of ours. Storage is local folder or NAS (SMB mount).

## Stack and constraints
- Swift 5.9+, SwiftUI, macOS 14+ minimum, Apple Silicon first.
- One Swift package with these targets:
  - `CairnCore`: manifest model, scanners, appliers, crypto, snapshot store. No UI imports.
  - `cairn` (CLI): swift-argument-parser. Everything the GUI does must be doable from the CLI.
  - `CairnApp`: SwiftUI app, thin layer over `CairnCore`.
- Dependencies: only `Yams` (YAML) and `swift-argument-parser`. Ask before adding any other.
- Keep `CairnCore` free of macOS-only types in the *model* layer (manifest structs, package IDs, setting keys) so a Windows/Linux port can reuse the schema. macOS-specific code lives in `Adapters/macOS`.

## Manifest (universal format)
YAML, versioned (`schema: 1`). Describes intent, not OS artifacts.

```yaml
schema: 1
device: { name: "aidans-mbp", os: macos, os_version: "14.5" }
created: 2026-11-21T10:00:00Z
packages:
  - id: vlc                    # canonical id
    kind: cask
    resolvers: { brew: vlc, winget: VideoLAN.VLC, apt: vlc }
    include: true
apps:
  - { id: "497799835", name: "Xcode", source: mas, include: true }
settings:
  - key: dock.autohide
    value: true
    platforms: [macos]
    adapter: { macos: { domain: com.apple.dock, key: autohide, type: bool } }
layout:
  dock: [ "/Applications/Safari.app", "/Applications/Mail.app" ]
sensitive:                     # always encrypted, never plaintext in the manifest
  - { type: wifi, ref: "vault://wifi/HomeNetwork" }
```

Rules:
- Every item has a stable `id` and an `include` flag (this is what the checklist UI toggles).
- Settings carry an abstract `key` plus a per-platform adapter. Unknown or macOS-only settings are kept but flagged `platforms: [macos]`.
- Manifest files are deterministic: sorted keys, stable ordering, so snapshot diffs are clean.
- Adding an optional section or field (like `layout.displays` or `shares`) that older backups simply lack does not bump `schema`. Bump it only for breaking changes (renamed, removed, or restructured fields), with a migration for old manifests.

## Categories (checklist tree)
Each category expands into individual items with their own checkboxes, a search box, and item counts. Presets: Minimal, Developer, Everything.

1. Packages: Homebrew formulae, casks, taps, services (`brew bundle dump`, `brew list`).
2. Mac App Store apps (`mas list`). Stored as pending; installed after the user signs in to the App Store.
3. Look and layout: Dock order and settings, Finder, menu bar, Mission Control, default apps, login items.
   - Displays: monitor arrangement (positions, main display, resolution, refresh rate, mirroring), matched by monitor id (vendor-model-hashed serial, `builtin` for the laptop screen), then by model. Read with CoreGraphics, restored with `cairn displays --from <manifest> [--apply]`. Rotation has no public API: it goes in the post-restore checklist.
4. System settings: keyboard, trackpad, display, sound, energy, accessibility.
5. App preferences: per-domain list from `defaults domains`, exported with `defaults export <domain> -`. Allowlist-first with a denylist for caches, window state, machine IDs, and anything containing tokens.
6. Developer: shell config, git config, SSH config (never private keys unless in the Sensitive tier).
7. Fonts (user-installed only).
8. Network shares: mapped network drives and file shares (SMB, AFP, NFS, WebDAV). Capture the share URL (`smb://server/share`), the username (never the password), whether it mounts at login, and Finder's "Connect to Server" favorites. Sources: current mounts (`mount`, filtered to network filesystems), Finder favorite servers (the `com.apple.LSSharedFileList.FavoriteServers` shared file list), and login items that point at shares. Restore reconnects via `open smb://...` (the Keychain or the user supplies the password) and recreates favorites and auto-mount login items. Share passwords belong in the Sensitive tier. System-wide autofs maps (`/etc/auto_master`) need admin rights: list them in the post-restore checklist, don't write them.
9. Sensitive (locked until encryption is enabled): Wi-Fi networks, VPN profiles, SSH keys, API tokens, network share passwords.

## Encryption design
- Two tiers. Ordinary items are plaintext YAML so snapshots can be diffed. Sensitive items are encrypted per item.
- A random 256-bit vault key encrypts secrets with AES-256-GCM (CryptoKit). The vault key is stored wrapped by a key derived from the user's password, so changing the password re-wraps one key.
- KDF for v1: PBKDF2-HMAC-SHA256 via CommonCrypto, at least 600,000 iterations, random 16-byte salt. The envelope stores a `kdf` identifier and parameters so we can move to Argon2id later without breaking old backups.
- A one-time recovery key (shown once, user saves it) is a second wrapping of the vault key. No password reset otherwise.
- Envelope format: `{ v, kdf, kdf_params, salt, wrapped_vault_key, recovery_wrapped_key }` plus per-item `{ nonce, ciphertext, tag }`.
- Each Mac may cache the unlocked vault key in its own Keychain after first unlock (opt-in).
- Sensitive checkboxes are disabled with a lock icon until a password is set.
- Wi-Fi: list with `networksetup -listpreferredwirelessnetworks <iface>`; read passwords with `security find-generic-password -D "AirPort network password" -wa "<SSID>"` (triggers an admin prompt per network). Detect the Wi-Fi interface at runtime, never hardcode `en0`. Restore with `networksetup` and the Keychain. Verify the exact restore commands in a throwaway VM before relying on them.

## Safety rules (important)
- Backup/scan code is read-only. Restore/apply code writes system state.
- Restore is dry-run by default: print a diff of what would change. Writes require `--apply` (CLI) or an explicit Apply button (GUI) after the diff is shown.
- Restore runs in dependency order: Xcode CLT, Homebrew, packages, MAS apps, settings, layout, then restart affected services (`killall Dock`, etc.).
- Never log secrets, passwords, or decrypted values. Zero sensitive buffers when done.
- Never run restore against my real user account during development. Develop and test restore in a throwaway macOS user or VM.
- Do not touch TCC permissions or SIP-protected areas. Anything macOS requires a manual approval for goes in a post-restore checklist shown to the user.

## Storage and auto-backup
- Snapshot store: a directory (local or an SMB-mounted NAS share) with one folder per snapshot, git-style history, so there are diffs and rollback.
- Auto-backup: a `launchd` agent (user LaunchAgent) runs the scan on a schedule and on watched plist changes (FSEvents), writing a new snapshot only if something changed.
- NAS: treat it as a mounted path. Handle it being offline (queue and retry, never block the UI).

## Sync (later milestone, not v1)
- Device groups with per-item scope: synced, this device only, ignored.
- NAS-hosted manifest as source of truth, plus optional direct device-to-device over Bonjour with an encrypted channel. Last-write-wins per key with a conflict view.

## Milestones
1. Manifest schema + `cairn scan` and `cairn diff` for Homebrew, MAS, Dock, `defaults` (read-only, unencrypted).
2. SwiftUI checklist UI over a live scan, export unencrypted manifest.
3. Snapshots + local/NAS store + `launchd` auto-backup.
   - Network shares scanner (read-only): mounts, Finder favorite servers, share login items.
4. Encryption vault + Sensitive tier (Wi-Fi first).
5. Restore (dry-run diff, then apply) in dependency order.
6. Sync tab.
7. Windows/Linux adapters.

## Conventions
- Small, testable functions; unit tests for the manifest model, diffing, crypto round-trips, and parsers, using recorded command-output fixtures (no live `brew`/`defaults` in unit tests).
- Shell out through one wrapper that captures stdout/stderr and exit codes and is mockable.
- Commit small and often with clear messages. Do not commit secrets or fixture files containing real Wi-Fi names or passwords.
- Ask me before adding dependencies, changing the manifest schema version, or running anything that writes system state.
