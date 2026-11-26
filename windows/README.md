# Cairn for Windows

A Windows app for Cairn: it backs up a PC's setup and sets a PC up from any Cairn
backup, whether that backup came from a Mac or from another PC. It uses the same
backup files and snapshot folders as the Mac app, so one folder or NAS share can
hold both.

- **Back up:** scans winget and Microsoft Store programs, a set of Windows settings,
  taskbar pins (in order), and Git and SSH config. Lines that look like secrets are
  left out. It saves a snapshot only when something changed.
- **Set up:** pick a backup, tick what you want, and click **Preview** to see what
  would change; nothing changes until you click **Set up**. From a Mac backup,
  Homebrew packages become winget packages, the Dock becomes the taskbar, and Mac
  settings with a Windows equivalent carry over.

## Projects

| Folder | What |
|---|---|
| `Cairn.Core` | Backup format, snapshots, scanning, setup. No UI. |
| `Cairn.Core.Tests` | xUnit tests, using made-up data only. |
| `Cairn.App` | The WinUI 3 window. Builds on Windows only. |

`Cairn.Core/catalog.json` is generated from the Mac app's catalog. Don't edit it by
hand; see `Tests/CairnCoreTests/WindowsCatalogTests.swift`.

## Build

Needs the .NET 8 SDK.

```
dotnet test windows/Cairn.Core.Tests
dotnet publish windows/Cairn.App/Cairn.App.csproj -c Release -r win-x64 -p:Platform=x64 -o publish/Cairn
```

The core and its tests also build on a Mac or Linux. GitHub Actions
(`.github/workflows/windows.yml`) builds the app on Windows and uploads it as a zip.
