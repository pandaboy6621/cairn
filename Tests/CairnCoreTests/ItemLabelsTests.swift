import Foundation
import Testing
@testable import CairnCore

@Suite struct ItemLabelsTests {
    @Test func settingTitles() {
        #expect(ItemLabels.title(settingKey: "keyboard.initial_key_repeat") == "Delay before keys repeat")
        #expect(ItemLabels.title(settingKey: "dock.show_recents") == "Show recents")
        #expect(ItemLabels.title(settingKey: "plain") == "Plain")
        // Every GNOME setting Cairn reads has a written-out name.
        for m in GnomeSettings.mappings {
            #expect(ItemLabels.settingTitles[m.key] != nil, "no title for \(m.key)")
        }
    }

    @Test func itemIDs() {
        #expect(ItemLabels.settingKey(itemID: "setting:dock.autohide") == "dock.autohide")
        #expect(ItemLabels.settingKey(itemID: "package:apt:git") == nil)
        let p = ItemLabels.package(itemID: "package:flatpak:org.gnome.Maps")
        #expect(p?.kind == "flatpak" && p?.id == "org.gnome.Maps")
        #expect(ItemLabels.package(itemID: "setting:dock.autohide") == nil)
        #expect(ItemLabels.value("true") == "On" && ItemLabels.value("bottom") == "bottom")
    }

    @Test func parsesDesktopEntries() {
        let text = """
        [Desktop Entry]
        # comment
        Name=Text Editor
        Name[de]=Texteditor
        Comment=Edit text files
        Icon=org.example.TextEditor
        Exec=editor %U

        [Desktop Action new-window]
        Name=New Window
        """
        #expect(DesktopEntries.parse(text) == DesktopEntry(name: "Text Editor", icon: "org.example.TextEditor",
                                                          comment: "Edit text files"))
        #expect(DesktopEntries.parse("[Desktop Action x]\nName=Nope") == nil)
        #expect(DesktopEntries.parse("[Desktop Entry]\nName=Bare\nIcon=")?.icon == nil)
    }

    @Test func findsEntriesForPackages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-desktop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ file: String, _ name: String) throws {
            try "[Desktop Entry]\nName=\(name)\nIcon=\(name.lowercased())\n"
                .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try write("org.example.Paint.desktop", "Paint")
        try write("notes_notes.desktop", "Notes")
        try write("radio_player.desktop", "Radio")
        try write("org.example.calc.desktop", "Calculator")

        #expect(DesktopEntries.lookup(kind: "flatpak", id: "org.example.Paint", directories: [dir])?.name == "Paint")
        #expect(DesktopEntries.lookup(kind: "snap", id: "notes", directories: [dir])?.name == "Notes")
        #expect(DesktopEntries.lookup(kind: "snap", id: "radio", directories: [dir])?.name == "Radio")
        #expect(DesktopEntries.lookup(kind: "apt", id: "calc", directories: [dir])?.name == "Calculator")
        #expect(DesktopEntries.lookup(kind: "apt", id: "git", directories: [dir]) == nil)
    }
}
