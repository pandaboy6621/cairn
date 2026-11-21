import ArgumentParser
import CairnCore

@main
struct CairnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cairn",
        abstract: "Back up, restore, and sync a Mac's setup.",
        version: Cairn.version
    )
}
