import SwiftUI

@main
struct MuxFlowApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1420, minHeight: 740)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1460, height: 940)
    }
}
