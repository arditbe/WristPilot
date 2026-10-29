import CoreBluetooth
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: MacSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("WristPilot").font(.headline)
                    Text("Your Mac's captain, on your wrist").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                StatusRow(ok: model.link.bluetoothState == .poweredOn && model.link.isAdvertising,
                          text: bluetoothText)
                StatusRow(ok: model.watchConnected, text: watchText)
                if model.accessibilityGranted {
                    StatusRow(ok: true, text: "Accessibility allowed")
                } else {
                    StatusRow(ok: false, text: "Needs Accessibility permission")
                    Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
                        .controlSize(.small)
                }
                if model.watchConnected, let stats = model.linkStats {
                    Text(stats).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let event = model.lastEvent {
                    Text("Last gesture: \(event)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Pointer").font(.subheadline.bold())
            LabeledSlider(title: "Precision", value: $settings.precision, range: 200...2500)
            LabeledSlider(title: "Speed", value: $settings.speed, range: 2000...20000)
            LabeledSlider(title: "Steadiness", value: $settings.steadiness, range: 0...1)
            LabeledSlider(title: "Smoothing", value: $settings.smoothing, range: 0...60)
            Text("Precision: slow, careful moves. Speed: quick flicks. Steadiness: higher locks out shake.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Invert X", isOn: $settings.invertX)
                Toggle("Invert Y", isOn: $settings.invertY)
            }

            Divider()

            Text("Gestures").font(.subheadline.bold())
            Picker("Pinch", selection: $settings.pinchAction) {
                ForEach(MouseAction.allCases) { Text($0.title).tag($0) }
            }
            Picker("Double pinch", selection: $settings.doublePinchAction) {
                ForEach(MouseAction.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Pinch, then tilt up/down to scroll", isOn: $settings.pinchScroll)
            if settings.pinchScroll {
                LabeledSlider(title: "Tilt scroll", value: $settings.pinchScrollSpeed, range: 500...10000)
            }
            LabeledSlider(title: "Crown scroll", value: $settings.crownScrollSpeed, range: 10...200)
            HStack {
                Toggle("Invert scroll", isOn: $settings.invertScroll)
                Toggle("Watch haptics", isOn: $settings.haptics)
            }

            Divider()

            HStack {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var bluetoothText: String {
        switch model.link.bluetoothState {
        case .poweredOn: return model.link.isAdvertising ? "Bluetooth ready" : "Starting Bluetooth…"
        case .unauthorized: return "Bluetooth not allowed (System Settings › Privacy)"
        case .poweredOff: return "Bluetooth is off"
        default: return "Bluetooth unavailable"
        }
    }

    private var watchText: String {
        guard model.watchConnected else { return "Waiting for Apple Watch…" }
        return model.watchPaused ? "Watch connected, paused" : "Watch connected"
    }
}

private struct StatusRow: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: $value, in: range)
        }
    }
}
