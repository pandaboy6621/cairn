import SwiftUI
import CairnCore

@main
struct CairnMainApp: App {
    var body: some Scene {
        WindowGroup("Cairn") {
            Text("Cairn \(Cairn.version)")
                .padding()
        }
    }
}
