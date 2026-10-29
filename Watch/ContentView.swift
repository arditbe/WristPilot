import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var link: BLEClient
    @EnvironmentObject private var engine: MotionEngine
    @State private var crown = 0.0
    @State private var lastCrown = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(link.status == .connected ? (link.macName ?? "Mac") : link.status.rawValue)
                        .font(.footnote)
                        .lineLimit(1)
                }

                Button {
                    engine.togglePause()
                } label: {
                    Label(engine.isPaused ? "Resume" : "Pause",
                          systemImage: engine.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(engine.isPaused ? .green : .orange)

                HStack(spacing: 6) {
                    Button("Click") { link.send(.button(.leftClick)) }
                    Button("Right") { link.send(.button(.rightClick)) }
                }

                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .focusable()
            .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000,
                                  sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: false)
            .onChange(of: crown) { _, value in
                let delta = value - lastCrown
                lastCrown = value
                if !engine.isPaused { link.send(.scroll(Float(delta)), reliable: false) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        TrainingView()
                    } label: {
                        Image(systemName: "hand.pinch")
                    }
                }
            }
            .navigationTitle("WristPilot")
        }
        .onAppear { engine.start() }
    }

    private var statusColor: Color {
        switch link.status {
        case .connected: return engine.isPaused ? .orange : .green
        case .searching, .connecting: return .yellow
        case .off, .unauthorized: return .red
        }
    }

    private var footer: String {
        if engine.isRunning && !engine.isBackgroundActive { return "Keep the screen on. Background mode isn't running." }
        if engine.isScrolling { return "Scrolling. Hold still to stop." }
        if !engine.isTrained { return "Tap the hand icon to train your pinch" }
        if let gesture = engine.lastGesture { return "Last: \(gesture)" }
        return "Pinch to click, double pinch for right click, pinch and tilt to scroll"
    }
}
