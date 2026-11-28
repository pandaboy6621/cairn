import Foundation
import Testing
@testable import CairnCore

/// Reading a Linux kit's output back into groups (made-up packages and repos).
@Suite struct KitReportTests {
    static let dryRun = """
    Software sources (2)
      example-browser is already set up
      would add chat-repo (https://chat.example.com/apt)
    Packages from apt (3)
      htop is already installed
      would install nettool
      would install chat-app (from chat-repo, once it's added)
    Apps from Flathub (1)
      would install org.example.Paint
    Snaps (1)
      notes is already installed
    Settings (2)
      show-hidden (org.gtk.gtk4.Settings.FileChooser) is already false
      would change color-scheme from 'default' to 'prefer-dark'
    Config files (1)
      would replace .gitconfig (keeping the old one as .gitconfig.before-cairn)

    Downloaded from their makers' websites, so get them there (see CHECKLIST.md): voice-app, remote-app
    Dry run: nothing changed. Run again with --apply to make these changes.
    See CHECKLIST.md for what to do by hand.
    """

    @Test func groupsADryRun() {
        let r = KitReport.parse(Self.dryRun)
        #expect(r.isDryRun)
        #expect(r.sections.map(\.title) == ["Software sources", "Packages from apt", "Apps from Flathub", "Snaps", "Settings", "Config files"])
        #expect(r.sections[0].items.map(\.status) == [.already, .willAdd])
        #expect(r.sections[1].count(.willInstall) == 2 && r.sections[1].count(.already) == 1)
        #expect(r.sections[4].changes.map(\.text) == ["would change color-scheme from 'default' to 'prefer-dark'"])
        #expect(r.sections[5].items.map(\.status) == [.willWrite])
        #expect(r.downloads == ["voice-app", "remote-app"])
        #expect(r.changeCount == 6)
        #expect(r.failed.isEmpty)
    }

    @Test func groupsAnApplyAndMarksWhatFailed() {
        let out = """
        Software sources (1)
          adding chat-repo (https://chat.example.com/apt)
        Packages from apt (2)
          installing nettool
        /usr/bin/deb-systemd-helper: error: some packaging noise
          installing chat-app
          ghost isn't in apt here
        Settings (1)
          changing color-scheme from 'default' to 'prefer-dark'
          skipped dock-fixed (not on this desktop)
        Config files (1)
          kept your old .gitconfig as .gitconfig.before-cairn
          wrote .gitconfig
        Not available here, install another way: ghost
        Didn't work: chat-app
        """
        let r = KitReport.parse(out)
        #expect(!r.isDryRun)
        #expect(r.sections[1].items.map(\.status) == [.done, .failed, .unavailable]) // noise left out
        #expect(r.sections[2].items.map(\.status) == [.done, .skipped])
        #expect(r.sections[3].items.map(\.text) == ["wrote .gitconfig"])
        #expect(r.failed == ["chat-app"] && r.unavailable == ["ghost"])
        #expect(r.changeCount == 4)
    }

    @Test func linesInPlainWords() {
        let r = KitReport.parse(Self.dryRun)
        func words(_ s: Int, _ i: Int) -> String { r.sections[s].items[i].title + " | " + r.sections[s].items[i].detail }
        #expect(words(0, 1) == "chat-repo | Will add this software source")
        #expect(words(1, 1) == "nettool | Will install")
        #expect(words(1, 2) == "chat-app | Will install from chat-repo")
        #expect(words(4, 0) == "show-hidden (org.gtk.gtk4.Settings.FileChooser) | Already false")
        #expect(words(4, 1) == "color-scheme | Will change from 'default' to 'prefer-dark'")
        #expect(words(5, 0) == ".gitconfig | Will replace it (your file is kept as .before-cairn)")
        let done = KitReport.parse("Packages from apt (2)\n  installing nettool\n  installing chat-app\nDidn't work: chat-app")
        #expect(done.sections[0].items.map(\.detail) == ["Installed", "Couldn't install"])
    }

    @Test func everythingAlreadyThereHasNoChanges() {
        let r = KitReport.parse("Snaps (1)\n  notes is already installed\nConfig files (1)\n  .gitconfig already matches\nDry run: nothing changed.")
        #expect(r.changeCount == 0 && r.sections.allSatisfy { $0.changes.isEmpty })
    }

    @Test func collectsStreamedLines() {
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let seen = Lines()
        let c = LineCollector { seen.all.append($0) }
        c.add(Data("Snaps (1)\n  no".utf8))
        c.add(Data("tes is already installed\nDry".utf8))
        c.finish()
        #expect(seen.all == ["Snaps (1)", "  notes is already installed", "Dry"])
        #expect(c.text == "Snaps (1)\n  notes is already installed\nDry")
    }
}
