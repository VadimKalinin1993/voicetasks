import SwiftUI

@main
struct ZadachiApp: App {
    @State private var store: TaskStore
    @State private var assistant: Assistant

    init() {
        let store = TaskStore()
        _store = State(initialValue: store)
        _assistant = State(initialValue: Assistant(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(assistant)
        }
    }
}
