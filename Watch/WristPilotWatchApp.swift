import SwiftUI

@main
struct WristPilotWatchApp: App {
    @StateObject private var link: BLEClient
    @StateObject private var engine: MotionEngine
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let link = BLEClient()
        _link = StateObject(wrappedValue: link)
        _engine = StateObject(wrappedValue: MotionEngine(link: link))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .environmentObject(engine)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.start() }
        }
    }
}
