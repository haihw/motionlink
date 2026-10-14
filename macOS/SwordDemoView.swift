import Observation
import SwiftUI

@MainActor @Observable
final class SwordDemoState {
    var cuts: Set<Int> = []
    var round = 0
    var isAutoplay = false
    var complete: Bool { cuts.count == 3 }
    func reset() { cuts = []; round += 1; isAutoplay = false }
    func watchDemo() { reset(); isAutoplay = true }
}

struct SwordDemoView: View {
    let session: MacSession
    @State private var game = SwordDemoState()
    private var live: Bool { session.deviceName != nil && !session.isPaused && !session.isStale && session.movement.isAvailable && !session.isDemo && session.isNeutralConfirmed }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Slice the\norchard.").font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("Three hanging melons. One blade.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    MacPairingCard(session: session)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(game.cuts.count)").font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(.orange)
                            Text("/ 3 SLICED").font(.caption.bold()).foregroundStyle(.secondary)
                        }
                        ForEach(WatermelonTarget.orchard) { fruit in
                            HStack {
                                Image(systemName: game.cuts.contains(fruit.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(game.cuts.contains(fruit.id) ? MotionTheme.accent : Color.secondary)
                                Text(fruit.name).font(.callout.weight(.medium))
                                Spacer()
                                Text(game.cuts.contains(fruit.id) ? "Sliced" : "Hanging")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(20).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 12) {
                        instruction("1", "Confirm your upright, steady neutral position.")
                        instruction("2", "Hold the phone as the handle. The blade extends from its top edge.")
                        instruction("3", "Swing and twist to slash. Hold steady to recenter without changing the angle.")
                    }
                    if let error = session.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                    Text("Move the handle to move the grip; rotate it to swing the blade. A steady hold recenters position while keeping your angle. Translation is estimated with 3× sensitivity.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }.frame(width: 340)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            ZStack {
                SwordArenaView(session: session, game: game)
                VStack {
                    HStack {
                        Label("SWORD DEMO", systemImage: "sparkles").font(.caption.weight(.bold)).tracking(2)
                            .foregroundStyle(.orange)
                        Spacer()
                        StatusPill(text: game.isAutoplay ? "Autoplay" : session.isSwordRecentering ? "Steady · angle preserved" : live ? "Phone control live" : session.deviceName != nil ? "Neutral setup required" : "Waiting for your phone", active: live)
                    }.padding(24)
                    Spacer()
                    if !game.isAutoplay && !session.isNeutralConfirmed {
                        neutralSetup
                    } else if game.complete {
                        VStack(spacing: 8) {
                            Text("Clean cut.").font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("All three watermelons sliced.").foregroundStyle(.secondary)
                        }
                        .padding(24).background(MotionTheme.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("Round complete. All three watermelons sliced.")
                    }
                    Spacer()
                    VStack(spacing: 12) {
                        HStack {
                            Button { session.resetNeutralPosition() } label: { Label("Reset neutral", systemImage: "scope") }
                                .disabled(session.deviceName == nil || game.isAutoplay)
                            Button { game.reset() } label: { Label("Reset fruit", systemImage: "arrow.counterclockwise") }
                                .keyboardShortcut("n", modifiers: .command)
                            Button {
                                if game.isAutoplay { game.isAutoplay = false }
                                else { game.watchDemo() }
                            } label: { Label(game.isAutoplay ? "Stop demo" : "Watch demo", systemImage: game.isAutoplay ? "stop.fill" : "play.fill") }
                        }.buttonStyle(.bordered).controlSize(.large)
                        Text(game.isAutoplay ? "Preview · scripted sword swings" : "Phone = sword handle · hold steady to recenter · angle preserved")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.bottom, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var neutralSetup: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone").font(.system(size: 42)).foregroundStyle(MotionTheme.accent)
            Text("Set your natural position").font(.title2.bold())
            Text("Hold the phone upright, top edge up, with the screen facing you. Keep it steady, then confirm this as your neutral grip.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Label(session.neutralCheck.isUpright ? "Upright" : "Hold upright", systemImage: session.neutralCheck.isUpright ? "checkmark.circle.fill" : "circle")
                Label(session.neutralCheck.isStill ? "Steady" : "Hold still", systemImage: session.neutralCheck.isStill ? "checkmark.circle.fill" : "circle")
            }.font(.caption).foregroundStyle(session.neutralCheck.isReady ? MotionTheme.accent : .secondary)
            ProgressView(value: session.neutralCheck.stableDuration, total: 0.6).tint(MotionTheme.accent)
            Button("Confirm neutral position") { session.confirmNeutralPosition() }
                .buttonStyle(.borderedProminent).tint(MotionTheme.accent)
                .foregroundStyle(session.neutralCheck.isReady ? Color.black : Color.secondary)
                .disabled(!session.neutralCheck.isReady || session.deviceName == nil || session.isPaused || session.isStale)
            Text(session.deviceName == nil ? "Pair your phone to start setup." : "Slicing stays paused until you confirm. Reset if the sword doesn’t match your natural grip.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(26).frame(maxWidth: 380)
        .background(MotionTheme.panel.opacity(0.98), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
        .padding(.horizontal, 24)
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).foregroundStyle(.orange)
                .frame(width: 22, height: 22).background(.orange.opacity(0.12), in: Circle())
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
