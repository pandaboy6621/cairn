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
```

## App

```bash
swift run CairnApp
```

The app scans on launch. Pick a category, check or uncheck items, use a preset (Minimal, Developer,
Everything), and click **Export Manifest** to save only the checked items. ⌘R scans again, ⌘E exports.

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

Preferences are filtered: window state, caches, identifiers, timestamps, large blobs, and anything that
looks like a credential are dropped. Every command goes through a read-only allowlist
(`CommandPolicy.readOnly`), so a scanner cannot run `defaults write`, `brew install`, and so on.
