import SwiftUI

/// Records the wearer's pinches, plus movement that isn't a pinch, and builds the classifier from them.
struct TrainingView: View {
    @EnvironmentObject private var engine: MotionEngine
    @StateObject private var trainer = Trainer()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(trainer.prompt)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if trainer.isRunning {
                    ProgressView(value: trainer.progress)
                } else {
                    Button(engine.isTrained ? "Retrain" : "Start") { trainer.start(engine: engine) }
                        .tint(.blue)
                    if engine.isTrained {
                        Button("Reset to defaults", role: .destructive) { engine.resetTraining() }
                            .font(.footnote)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Train")
        .onDisappear { trainer.cancel(engine: engine) }
    }
}

@MainActor
final class Trainer: ObservableObject {
    @Published private(set) var prompt = "Hold your hand up the way you'll use it. Pinch each time the watch taps you."
    @Published private(set) var progress = 0.0
    @Published private(set) var isRunning = false

    private static let singles = 8
    private static let doubles = 4
    private var task: Task<Void, Never>?
    private var listening = false
    private var heard: [(onset: TimeInterval, window: [MotionSample])] = []

    func start(engine: MotionEngine) {
        task?.cancel()
        task = Task { await run(engine: engine) }
    }

    func cancel(engine: MotionEngine) {
        guard isRunning else { return }
        task?.cancel()
        engine.endTraining(saving: nil)
        isRunning = false
    }

    private func run(engine: MotionEngine) async {
        isRunning = true
        progress = 0
        engine.beginTraining { [weak self] window, onset in
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.heard.append((onset, window))
            }
        }

        var pinches: [[MotionSample]] = []
        var noise: [[MotionSample]] = []
        let steps = Double(Self.singles + Self.doubles + 1)
        var done = 0.0

        var count = 0
        while count < Self.singles {
            prompt = "Pinch once after the tap\n\(count + 1) of \(Self.singles)"
            guard await pause(0.9) else { return }
            engine.playHaptic(.click)
            guard await listen(for: 2) else { return }
            guard let strongest = heard.max(by: { Self.peak($0.window) < Self.peak($1.window) }) else {
                prompt = "Didn't feel that one. Pinch a little firmer."
                guard await pause(1.2) else { return }
                continue
            }
            pinches.append(strongest.window)
            // Weaker knocks right after a pinch are the fingers letting go. Teach those as "not a pinch".
            for other in heard where other.onset > strongest.onset && other.onset - strongest.onset < 0.6
                && Self.peak(other.window) < Self.peak(strongest.window) * 0.6 {
                noise.append(other.window)
            }
            count += 1
            done += 1
            progress = done / steps
        }

        count = 0
        while count < Self.doubles {
            prompt = "Now double pinch after the tap\n\(count + 1) of \(Self.doubles)"
            guard await pause(0.9) else { return }
            engine.playHaptic(.click)
            guard await listen(for: 2.5) else { return }
            let strongest = Array(heard.sorted { Self.peak($0.window) > Self.peak($1.window) }.prefix(2))
            guard strongest.count == 2, abs(strongest[0].onset - strongest[1].onset) < 0.7 else {
                prompt = "Didn't feel two pinches. Try again, a little firmer."
                guard await pause(1.2) else { return }
                continue
            }
            pinches += strongest.map(\.window)
            count += 1
            done += 1
            progress = done / steps
        }

        prompt = "Last step: move your hand around, point at things and wiggle your fingers. Don't pinch."
        guard await pause(2.5) else { return }
        guard await listen(for: 10) else { return }
        noise += heard.map(\.window)

        engine.endTraining(saving: GestureModel.train(pinches: pinches, noise: noise))
        progress = 1
        prompt = "Done! Pinch to click, double pinch to right click, pinch then tilt to scroll."
        engine.playHaptic(.success)
        isRunning = false
    }

    private func listen(for seconds: Double) async -> Bool {
        heard = []
        listening = true
        let ok = await pause(seconds)
        listening = false
        return ok
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private static func peak(_ window: [MotionSample]) -> Double {
        window.map(\.energy).max() ?? 0
    }
}
