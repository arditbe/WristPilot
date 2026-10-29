import SwiftUI

@main
struct WristPilotMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(model.settings)
        } label: {
            Image(systemName: model.watchConnected ? "applewatch.radiowaves.left.and.right" : "applewatch")
        }
        .menuBarExtraStyle(.window)
    }
}
