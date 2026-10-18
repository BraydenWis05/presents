import SwiftUI

/// Reveal night: the pink "tonight it opens" screen, then the reveal itself.
struct RevealNightView: View {
    @Environment(RollStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var openedRollID: UUID?

    var body: some View {
        if let id = openedRollID, let roll = store.roll(id) {
            PresentationNight(roll: roll) { dismiss() }
        } else if let roll = store.activeRoll {
            night(roll)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func night(_ roll: Roll) -> some View {
        ZStack {
            AppBackground(intense: true)
            Sparkles(count: 12)
            VStack(spacing: 22) {
                HStack {
                    Button("Not yet") { dismiss() }
                        .buttonStyle(.frostedPill)
                    Spacer()
                    AirPlayButton().frame(width: 44, height: 44)
                }
                Spacer()
                TagLabel(roll.name)
                Text("Tonight,\nit opens.")
                    .font(.display(46))
                    .multilineTextAlignment(.center)
                Text("Open it when you're all together.")
                    .font(.copy(16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.secondary)

                Text("Put it on the TV.")
                    .font(.copy(13))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                Label("AirPlay or mirror to the TV", systemImage: "tv")
                    .font(.copy(13))
                    .foregroundStyle(Palette.secondary)
                Button("Open it") {
                    openedRollID = roll.id
                    withAnimation(.easeInOut(duration: 0.6)) { store.reveal() }
                }
                .buttonStyle(.pill)
                .disabled(roll.moments.isEmpty)
            }
            .foregroundStyle(Palette.ink)
            .padding(24)
        }
    }
}
