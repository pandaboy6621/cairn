import Testing
@testable import CairnCore

@Test func versionIsSet() {
    #expect(!Cairn.version.isEmpty)
}
