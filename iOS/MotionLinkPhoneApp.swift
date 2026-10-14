import SwiftUI

@main
struct MotionLinkPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = PhoneSession()
    var body: some Scene {
        WindowGroup {
            PhoneView(session: session)
                .preferredColorScheme(.dark)
                .task { session.discover() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { session.discover() }
                    else if phase == .background { session.suspend() }
                }
        }
    }
}

struct PhoneView: View {
    @Bindable var session: PhoneSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "gyroscope").font(.title2).foregroundStyle(MotionTheme.accent)
                    Text("MotionLink").font(.title2.bold())
                    Spacer()
                    Text("SENDER").font(.caption2.bold()).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.connectedName == nil ? "Your movement.\nOn the big screen." : "You’re in motion.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(session.connectedName.map { "Connected to \($0)" } ?? "Open MotionLink on your Mac, then pair below.")
                        .foregroundStyle(.secondary)
                }
                StatusPill(text: session.status, active: session.isStreaming)
                if session.connectedName != nil {
                    MovementReadout(estimate: session.movement)
                    connectedControls
                }
                else { pairingControls }
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                SensorCard(title: "ROTATION RATE", value: session.sample?.rotationRate ?? .zero, unit: "rad/s")
                SensorCard(title: "NEUTRAL ACCELERATION", value: session.movement.acceleration, unit: "m/s²")
                Label("Keep this app open while streaming. Hold your phone still and upright, then set the neutral pose.", systemImage: "iphone")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(MotionTheme.background)
    }

    private var pairingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PAIR WITH A MAC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("6-digit Mac code", text: $session.pairingCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.title2, design: .monospaced))
                .padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: session.pairingCode) { _, value in
                    session.pairingCode = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                }
                .accessibilityLabel("Mac pairing code")
            if session.nearbyMacs.isEmpty {
                HStack { ProgressView(); Text("Searching for a nearby Mac…").font(.callout) }
                Text("Use the same Wi-Fi network and allow Local Network access on both devices.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Search again") { session.suspend(); session.discover() }
            }
            ForEach(session.nearbyMacs) { mac in
                Button { session.connect(to: mac) } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(mac.name).lineLimit(1)
                        Spacer()
                        if session.isConnecting { ProgressView() }
                        else { Image(systemName: "arrow.up.right") }
                    }.padding(14).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(MotionTheme.accent).foregroundStyle(.black)
                .disabled(session.pairingCode.count != 6 || session.isConnecting)
            }
            if session.isConnecting { Button("Cancel") { session.disconnect() } }
        }
        .padding(20).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private var connectedControls: some View {
        VStack(spacing: 14) {
            Image(systemName: session.isStreaming ? "sensor.fill" : "pause.circle")
                .font(.system(size: 64)).foregroundStyle(MotionTheme.accent)
                .padding(.vertical, 10)
            Text(session.isStreaming ? "Move, tilt, and rotate" : "Motion paused").font(.title3.bold())
            Button(session.isStreaming ? "Pause streaming" : "Resume streaming") { session.toggleStreaming() }
                .buttonStyle(.borderedProminent).tint(MotionTheme.accent).foregroundStyle(.black)
                .disabled(!session.hasMotion)
            Button("Set neutral pose") { session.calibrate() }.disabled(session.sample == nil)
            Button("Reset speed · hold still") { session.resetMovement(notifyMac: true) }.disabled(!session.movement.isAvailable)
            Button("Disconnect", role: .destructive) { session.disconnect() }
        }
        .frame(maxWidth: .infinity).padding(24)
        .background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview { PhoneView(session: PhoneSession()).preferredColorScheme(.dark) }
