import SwiftUI

/// Opened from an invite link: confirm and join a roll someone started.
struct JoinFromLinkView: View {
    var invite: RollInvite
    @Environment(RollStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var needsName: Bool { store.state.me.isEmpty }
    private var canJoin: Bool { !needsName || !name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isFull: Bool { invite.members.count >= GroupRules.maxSize }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 22) {
                TagLabel("You're invited")
                Text(invite.name).font(.display(46)).foregroundStyle(Palette.ink)
                Text("With \(Together.names(invite.members)). Opens \(invite.revealDate.stamp).")
                    .font(.copy(16))
                    .foregroundStyle(Palette.secondary)

                if needsName {
                    TextField("", text: $name, prompt: Text("What friends call you").foregroundStyle(Palette.secondary))
                        .font(.display(26))
                        .foregroundStyle(Palette.ink)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.fill))
                }

                if let current = store.activeRoll {
                    Text("You're already in \(current.name). Open that one first.")
                        .font(.copy(15)).foregroundStyle(Palette.secondary)
                } else if isFull {
                    Text("This one's full.").font(.copy(15)).foregroundStyle(Palette.secondary)
                } else {
                    Button("Join") { join() }
                        .buttonStyle(.pill)
                        .disabled(!canJoin)
                        .opacity(canJoin ? 1 : 0.4)
                }
                Button("Not now") { dismiss() }
                    .font(.tag(14))
                    .foregroundStyle(Palette.secondary)
                Spacer()
            }
            .padding(24)
            .padding(.top, 30)
        }
        .preferredColorScheme(.dark)
    }

    private func join() {
        if needsName { store.state.me = name.trimmingCharacters(in: .whitespaces) }
        store.joinRoll(invite)
        store.pendingInvite = nil
        dismiss()
    }
}
