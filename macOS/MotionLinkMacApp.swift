import SwiftUI

@main
struct MotionLinkMacApp: App {
    @State private var session = MacSession()
    var body: some Scene {
        Window("MotionLink", id: "main") {
            MacView(session: session)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 680)
                .task { session.start() }
                .onDisappear { session.stop() }
        }
        .defaultSize(width: 1160, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct MacView: View {
    let session: MacSession
    @State private var mode = Mode.sword
    enum Mode: String, CaseIterable, Identifiable {
        case studio = "Motion Studio", sword = "Sword Demo"
        var id: Self { self }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gyroscope").font(.title2).foregroundStyle(MotionTheme.accent)
                Text("MotionLink").font(.title2.bold())
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 300).padding(.leading, 16)
                Spacer()
                StatusPill(text: session.isDemo ? "Demo motion" : session.status,
                           active: session.deviceName != nil && !session.isPaused && !session.isStale)
            }
            .padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 22)
            Divider().overlay(.white.opacity(0.04))
            if mode == .studio { studio }
            else { SwordDemoView(session: session) }
        }.background(MotionTheme.background)
            .onChange(of: mode) { _, mode in
                if mode == .sword && session.isDemo { session.toggleDemo() }
            }
    }

    private var studio: some View {
            HStack(spacing: 0) {
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("A live view of\nyour iPhone.").font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Tilt, turn, and move.").foregroundStyle(.secondary)
                    }
                    MacPairingCard(session: session)
                    if let error = session.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    MovementReadout(estimate: session.movement)
                    SensorCard(title: "ROTATION RATE", value: session.sample?.rotationRate ?? .zero, unit: "rad/s")
                    SensorCard(title: "NEUTRAL ACCELERATION", value: session.movement.acceleration, unit: "m/s²")
                    HStack {
                        Text("RECEIVE RATE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(session.receivedFPS) Hz").font(.system(.callout, design: .monospaced)).foregroundStyle(MotionTheme.accent)
                    }
                }.padding(24)
                }.frame(width: 340)
                Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                ZStack(alignment: .bottom) {
                    PhoneModelView(orientation: session.orientation, movement: session.movement, rotationRate: session.movement.isAvailable ? (session.sample?.rotationRate ?? .zero) : .zero)
                    VStack(spacing: 14) {
                        HStack(spacing: 18) {
                            axis("Movement estimate", MotionTheme.accent)
                            axis("Acceleration", .orange)
                            axis("Gyro X / Y / Z", .cyan)
                        }
                        HStack {
                            Button { session.calibrate() } label: { Label("Set neutral pose", systemImage: "scope") }
                                .disabled(session.sample == nil || session.isDemo)
                                .keyboardShortcut("r", modifiers: .command)
                            Button { session.resetMovement(notifyPhone: true) } label: { Label("Reset speed", systemImage: "speedometer") }
                                .disabled(!session.movement.isAvailable || session.isDemo)
                            Button { session.toggleDemo() } label: {
                                Label(session.isDemo ? "Stop demo" : "Try demo", systemImage: session.isDemo ? "stop.fill" : "play.fill")
                            }.disabled(session.deviceName != nil)
                        }.buttonStyle(.bordered).controlSize(.large)
                        Text(session.isDemo ? "Preview · simulated motion" : "Axes and movement relative to your neutral pose · hold still to reset")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.bottom, 28)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private func axis(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MacPairingCard: View {
    let session: MacSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let name = session.deviceName {
                Label(name, systemImage: "iphone").font(.headline)
                Text("Hold your iPhone still and upright, then set its neutral pose to align the model.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Disconnect phone", role: .destructive) { session.disconnect() }
            } else {
                Text("CONNECT YOUR IPHONE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(session.pairingCode).font(.system(size: 36, weight: .semibold, design: .monospaced)).tracking(5)
                    .foregroundStyle(MotionTheme.accent).textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(session.pairingCode)")
                Text("Select \(session.macName) in the iPhone app and enter this code.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("Same Wi-Fi · local connection", systemImage: "wifi").font(.caption).foregroundStyle(.secondary)
                if !session.isListening { Button("Start receiver") { session.restart() } }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

#Preview { MacView(session: MacSession()).frame(width: 1160, height: 780).preferredColorScheme(.dark) }
