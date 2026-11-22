# Cairn

Back up, restore, and sync a Mac's *setup* (not its files). See [CLAUDE.md](CLAUDE.md) for the design.

**Status:** Milestones 1–2. Scanning, diffing, and the checklist UI are read-only and never change system state.

## Requirements

- macOS 14+, Apple Silicon
- Swift 5.9+ (the Command Line Tools are enough; Xcode is not required)
- Optional, for the scanners: Homebrew, `mas` (`brew install mas`)

## Build and test

```bash
swift build
swift test
```

## CLI

```bash
# Scan everything to stdout, or to a file
swift run cairn scan
swift run cairn scan -o ~/Desktop/mac.yaml

# Only some scanners, plus an extra preferences domain
swift run cairn scan --only brew,mas
swift run cairn scan --only defaults --domain com.example.SomeApp

# Compare two manifests (exit 0 = same, 1 = different)
swift run cairn diff old.yaml new.yaml

# Save a snapshot in the backup folder (the app's, or --to), only if something changed
swift run cairn backup
swift run cairn backup --to /Volumes/NAS/Cairn

# Snapshot history, and what changed (newest vs its parent, or any two)
swift run cairn snapshots
swift run cairn snapshots --diff
swift run cairn snapshots --diff 2026-11-20 2026-11-21-101500

# Roll back: restore a snapshot (dry run until --apply; test in a VM)
swift run cairn restore --from 2026-11-20-090000

# Automatic backups (a user LaunchAgent): on, off, or status
swift run cairn auto-backup on --every 60
swift run cairn auto-backup status
```

### Snapshots

Snapshots live in the backup folder as `snapshots/<device>/<yyyy-MM-dd-HHmmss>/`, each with
`manifest.yaml` and `snapshot.yaml` (parent, trigger, a `+added -removed ~changed` summary, and the
items you left unchecked, so later backups keep your selection). A new snapshot is written only when
the setup changed. If the backup folder is a NAS share that isn't mounted, snapshots wait in
`~/Library/Application Support/Cairn/Queue` and are copied over on the next run that can reach it.
Cairn never creates a missing backup folder other than its own default, so an unmounted share can't
become a stray folder under `/Volumes`.

## App

Build a real `Cairn.app` (release build, icon, ad-hoc signed for this Mac) and put it in `~/Applications`,
so it shows up in Launchpad and Spotlight:

```bash
scripts/build-app.sh --install
```

Without `--install` it only builds `dist/Cairn.app`. Run the script again after pulling changes. The
bundle also contains the CLI at `Cairn.app/Contents/MacOS/cairn`.

While developing, you can skip the bundle:

```bash
swift run CairnApp
```

The app opens on **Home**: setup stats plus Back Up, Restore (preview a backup against this Mac), and
Sync cards. It scans on launch, starting from what you unchecked last time. Pick a category, check or uncheck items, use a preset (Minimal, Developer,
Everything), and click **Back Up** to save the checked items as a snapshot. Settings (⌘,) turns on
automatic backups. ⌘R scans again, ⌘E backs up.

Debug builds can save a picture of the window without Screen Recording permission:

```bash
CAIRN_SNAPSHOT=/tmp/cairn.png CAIRN_SNAPSHOT_SELECT=lookAndLayout swift run CairnApp
```

## What gets scanned

| Scanner    | Reads                                                                 |
|------------|-----------------------------------------------------------------------|
| `brew`     | `brew leaves --installed-on-request`, `brew list --cask`, `brew tap`  |
| `mas`      | `mas list`                                                            |
| `dock`     | `defaults export com.apple.dock -` (tile order and Dock settings)     |
| `defaults` | `defaults export <domain> -` for an allowlist of Apple and common third-party domains |
| `shares`   | `mount` (SMB, AFP, NFS, WebDAV mounts) and Finder's Connect to Server favorites; usernames, never passwords |

Preferences are filtered: window state, caches, identifiers, timestamps, large blobs, and anything that
looks like a credential are dropped. Every command goes through a read-only allowlist
(`CommandPolicy.readOnly`), so a scanner cannot run `defaults write`, `brew install`, and so on.
