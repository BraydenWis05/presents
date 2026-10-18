import SwiftUI
import PhotosUI

/// Profile and group settings, behind the avatar.
struct SettingsView: View {
    @Environment(RollStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmOpenNow = false
    @State private var confirmLeave = false
    @State private var confirmErase = false
    @State private var takeBack: Moment?

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                // Profile
                Section {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Avatar(name: store.state.me, size: 64)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Palette.backgroundTop)
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(Palette.ink))
                                }
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Your name", text: $store.state.me)
                                .font(.display(26))
                            if let roll = store.activeRoll {
                                Text("In \(roll.name)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                if let roll = store.activeRoll {
                    // Group
                    Section {
                        ForEach(roll.members, id: \.self) { name in
                            HStack(spacing: 12) {
                                Avatar(name: name, size: 32)
                                Text(name == store.state.me ? "\(name) (you)" : name)
                                Spacer()
                            }
                        }
                        if let link = store.inviteLink, roll.members.count < GroupRules.maxSize {
                            ShareLink(
                                item: link,
                                subject: Text("Join \(roll.name)"),
                                message: Text("Join \"\(roll.name)\" on Presents. It stays sealed until we open it together.")
                            ) {
                                Label("Invite", systemImage: "person.badge.plus")
                            }
                        }
                    } header: {
                        Text("\(roll.name) · \(roll.members.count) of \(GroupRules.maxSize)")
                    }

                    // Reveal
                    Section {
                        DatePicker(
                            "Opens",
                            selection: Binding(
                                get: { roll.revealDate },
                                set: { date in store.updateActive { $0.revealDate = date } }
                            ),
                            in: Date.now...,
                            displayedComponents: .date
                        )
                        Button("Open it tonight") { confirmOpenNow = true }
                    } header: {
                        Text("Reveal night")
                    } footer: {
                        Text("Move it if life gets in the way.")
                    }

                    // Your moments
                    Section {
                        if store.myTakeBacks.isEmpty {
                            Text("Nothing added yet.").foregroundStyle(.secondary)
                        }
                        ForEach(store.myTakeBacks) { moment in
                            HStack {
                                Image(systemName: moment.kind.symbol).foregroundStyle(moment.kind.orbColor).frame(width: 24)
                                Text(moment.kind.title)
                                Spacer()
                                Text(moment.createdAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("Take back", role: .destructive) { takeBack = moment }
                            }
                        }
                    } header: {
                        Text("Your moments")
                    } footer: {
                        Text("Swipe to take one back. You won't see what it was.")
                    }
                }

                // Privacy & about
                Section {
                    NavigationLink("How privacy works") { PrivacyView() }
                    LabeledContent("Version", value: version)
                } header: {
                    Text("About")
                }

                // Danger zone
                Section {
                    if store.activeRoll != nil {
                        Button("Leave this chapter", role: .destructive) { confirmLeave = true }
                    }
                    Button("Erase everything on this phone", role: .destructive) { confirmErase = true }
                } footer: {
                    Text("Everything lives only on this phone for now. Erasing can't be undone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: photoItem) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self),
                          let small = UIImage(data: data)?.downscaled(maxSide: 240).jpegData(compressionQuality: 0.8) else { return }
                    var avatars = store.state.avatars ?? [:]
                    avatars[store.state.me] = small
                    store.state.avatars = avatars
                }
            }
            .confirmationDialog("Take this back for good?", isPresented: Binding(get: { takeBack != nil }, set: { if !$0 { takeBack = nil } }), titleVisibility: .visible) {
                Button("Take it back", role: .destructive) { if let m = takeBack { store.takeBack(m) } }
            }
            .confirmationDialog("Open it tonight?", isPresented: $confirmOpenNow, titleVisibility: .visible) {
                Button("Open tonight") { store.updateActive { $0.revealDate = .now } }
            } message: {
                Text("For when you're all together early.")
            }
            .confirmationDialog("Leave this chapter?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { store.leaveActiveRoll(); dismiss() }
            } message: {
                Text("What you added stays for the others. You'll miss reveal night.")
            }
            .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { store.eraseEverything(); dismiss() }
            } message: {
                Text("Your name and every chapter, gone from this phone.")
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                row("lock", "Sealed, even from you", "Whatever you add is sealed the moment you save it. You can't look at it again until reveal night.")
                row("person.2", "Only your group", "Only the people you started with, or who got your link.")
                row("tv", "Opened together", "Everything opens at once, on one screen, with everyone in the room.")
                row("eye.slash", "Hide anything", "During the reveal, anyone can quietly hide a moment. Nobody sees who did.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Privacy")
    }

    private func row(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
