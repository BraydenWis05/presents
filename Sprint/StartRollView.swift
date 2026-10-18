import SwiftUI
import PhotosUI
import AudioToolbox

/// Onboarding, ported from Finley's moment-onboarding.html (focus style, no phone number):
/// welcome → your name → a face → make your group by holding phones together → name it → start.
struct StartRollView: View {
    var onDone: (() -> Void)?

    @Environment(RollStore.self) private var store

    private enum Step: Int { case welcome, name, photo, group, share }

    @State private var step: Step = .welcome
    @State private var myName = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: Data?
    @State private var myColor: UInt32 = Self.colors[0]
    @State private var groupName = ""
    @State private var revealDate = Calendar.current.date(byAdding: .month, value: 2, to: .now) ?? .now
    /// After naming the group: its own step for when it opens.
    @State private var askingDate = false
    @State private var gather: GatherSession?
    @State private var arrived: [String] = []
    @State private var bumpSide: Edge = .leading
    @State private var wave = 0
    @State private var merging = false
    @State private var sealedLink: URL?
    @FocusState private var nameFocused: Bool
    @FocusState private var groupFocused: Bool

    static let colors: [UInt32] = [0xBCD3DC, 0xE2642E, 0xD257B4, 0x1A86A6, 0xE5D24A]

    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: Color(hex: 0x0B1B21), location: 0), .init(color: Color(hex: 0x0A1518), location: 0.5),
                .init(color: Color(hex: 0x0A1012), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            Group {
                switch step {
                case .welcome: welcome
                case .name, .photo: profile
                case .group: groupView
                case .share: shareView
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))

            GrainOverlay().opacity(0.8).allowsHitTesting(false).ignoresSafeArea()
        }
        .animation(.easeOut(duration: 0.5), value: step)
        .preferredColorScheme(.dark)
        .keyboardDoneButton()
        .onAppear {
            if !store.state.me.isEmpty {
                myName = store.state.me
                photo = store.state.avatars?[store.state.me]
                startGathering()
            }
        }
        .onDisappear { gather?.stop() }
        .onChange(of: gather?.names ?? []) { old, new in
            for name in new where !arrived.contains(name) { bump(name) }
            arrived.removeAll { !new.contains($0) }
            saveFriendPhotos()
        }
        .onChange(of: gather?.people.values.compactMap { $0 }.count ?? 0) { _, _ in saveFriendPhotos() }
        .onChange(of: gather?.invite?.rollID) { _, _ in
            guard let invite = gather?.invite else { return }
            saveFriendPhotos()
            withAnimation(.easeInOut(duration: 1)) { merging = true }
            Task {
                try? await Task.sleep(for: .seconds(1.1))
                store.joinRoll(invite)
                gather?.stop()
                onDone?()
            }
        }
        .onChange(of: photoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    photo = image.downscaled(maxSide: 240).jpegData(compressionQuality: 0.8)
                }
            }
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                ForEach(Array(Self.colors.enumerated()), id: \.offset) { i, c in
                    let a = -Double.pi / 2 + Double(i) * 2 * .pi / 5
                    Circle()
                        .fill(Color(hex: c))
                        .frame(width: 120, height: 120)
                        .blur(radius: 34)
                        .offset(x: cos(a) * 34, y: sin(a) * 34)
                        .opacity(0.85)
                }
                FiveDotMark(mono: true).frame(width: 56, height: 56)
            }
            .frame(height: 260)
            Spacer().frame(height: 60)
            Text("capture a moment,\ntogether")
                .font(.displayItalic(44))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(hex: 0xF3F5F2))
            Text("A small group, one moment at a time.")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0x8B9C9F))
                .padding(.top, 10)
            Spacer()
            wideButton("Get started") { click(); step = store.state.me.isEmpty ? .name : .group }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
    }

    // MARK: Name + photo (focus style)

    private var profile: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    click()
                    step = step == .photo ? .name : .welcome
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { i in
                        Capsule().fill(.white.opacity(i <= step.rawValue - 1 ? 0.9 : 0.18)).frame(height: 3)
                    }
                }
                .frame(maxWidth: .infinity)
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Group {
                if step == .name {
                    VStack(alignment: .leading, spacing: 20) {
                        question("what do friends call you?")
                        TextField("", text: $myName, prompt: Text("Your first name").foregroundStyle(.white.opacity(0.3)))
                            .font(.display(34))
                            .foregroundStyle(.white)
                            .textContentType(.givenName)
                            .focused($nameFocused)
                            .submitLabel(.continue)
                            .onSubmit(nextFromName)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
                        help("This is how you show up in your groups.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The whole area focuses the field, not just the text glyphs.
                    .contentShape(Rectangle())
                    .onTapGesture { nameFocused = true }
                    .onAppear { Task { try? await Task.sleep(for: .seconds(0.35)); nameFocused = true } }
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        question("add a face, \(myName.trimmingCharacters(in: .whitespaces).isEmpty ? "friend" : myName.trimmingCharacters(in: .whitespaces))")
                        HStack(spacing: 20) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                faceCircle(size: 108)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                PhotosPicker(selection: $photoItem, matching: .images) {
                                    Text(photo == nil ? "Choose photo" : "Change photo")
                                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                        .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                                }
                                Text("or pick a color").font(.system(size: 13)).foregroundStyle(Color(hex: 0x8B9C9F))
                                HStack(spacing: 10) {
                                    ForEach(Self.colors, id: \.self) { c in
                                        Button {
                                            click()
                                            myColor = c
                                            photo = nil
                                            photoItem = nil
                                        } label: {
                                            Circle().fill(Color(hex: c)).frame(width: 26, height: 26)
                                                .overlay(Circle().stroke(.white, lineWidth: c == myColor && photo == nil ? 2 : 0).padding(-3))
                                        }
                                    }
                                }
                            }
                        }
                        help("Friends see it next to everything you add.")
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 60)
            .id(step)
            .transition(.opacity.combined(with: .offset(x: 16)))

            Spacer()
            wideButton(step == .name ? "Continue" : (photo == nil ? "Skip for now" : "Looks good"),
                       enabled: step == .photo || !myName.trimmingCharacters(in: .whitespaces).isEmpty) {
                step == .name ? nextFromName() : finishProfile()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
    }

    private func faceCircle(size: CGFloat) -> some View {
        ZStack {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(hex: myColor)
                Text(String(myName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.displayItalic(size * 0.48))
                    .foregroundStyle(Color(hex: 0x0B1316).opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: Color(hex: myColor).opacity(photo == nil ? 0.6 : 0), radius: 24)
    }

    private func nextFromName() {
        guard !myName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        click()
        nameFocused = false
        step = .photo
    }

    private func finishProfile() {
        click()
        let name = myName.trimmingCharacters(in: .whitespaces)
        store.state.me = name
        var avatars = store.state.avatars ?? [:]
        avatars[name] = photo ?? Self.colorAvatar(myColor, initial: String(name.prefix(1)).uppercased())
        store.state.avatars = avatars
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        startGathering()
    }

    /// A color-swatch avatar becomes a small image, so friends' phones see the same face.
    private static func colorAvatar(_ hex: UInt32, initial: String) -> Data? {
        let side: CGFloat = 160
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIColor(Color(hex: hex)).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let font = UIFont(name: Fonts.serifItalic, size: side * 0.5) ?? .italicSystemFont(ofSize: side * 0.5)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 0.05, alpha: 0.85)]
            let size = (initial as NSString).size(withAttributes: attrs)
            (initial as NSString).draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    // MARK: Make your group

    private var groupView: some View {
        let namer = gather?.isNamer ?? true
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(arrived.isEmpty ? "just you so far" : "\(arrived.count + 1) people")
                    .font(.system(size: 13)).foregroundStyle(Color(hex: 0x8B9C9F))
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            VStack(spacing: 8) {
                question("make your group").frame(maxWidth: .infinity)
                help("Hold your phone against a friend's phone to add them.").multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.horizontal, 40)

            GeometryReader { geo in
                ring(in: geo.size)
            }
            .frame(height: 320)

            Group {
                if arrived.isEmpty {
                    HStack(spacing: 0) {
                        Text("waiting for a phone nearby")
                        Text("…")
                    }
                } else if !namer {
                    Text("\(gather?.namerName ?? "Someone") is naming it")
                } else {
                    Text(arrived.count >= GroupRules.maxSize - 1 ? "everyone's in" : "\(arrived.last ?? "") joined")
                }
            }
            .font(.displayItalic(22))
            .foregroundStyle(Color(hex: 0xF3F5F2))
            .contentTransition(.opacity)

            Spacer()

            if !arrived.isEmpty {
                if namer {
                    VStack(spacing: 12) {
                        TextField("", text: $groupName, prompt: Text(placeholderName).foregroundStyle(.white.opacity(0.3)))
                            .font(.display(26))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .focused($groupFocused)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
                            .contentShape(Rectangle())
                            .onTapGesture { groupFocused = true }
                            .onChange(of: groupName) { _, new in gather?.type(new) }
                        wideButton("Next") { withAnimation(.easeInOut(duration: 0.4)) { askingDate = true } }
                    }
                    .opacity(askingDate ? 0 : 1)
                    .overlay {
                        if askingDate {
                            VStack(spacing: 14) {
                                Text("when do you open it?")
                                    .font(.displayItalic(28))
                                    .foregroundStyle(Color(hex: 0xF3F5F2))
                                Text("Everything stays sealed until then.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(hex: 0x8B9C9F))
                                HStack(spacing: 8) {
                                    ForEach([(1, "1 month"), (2, "2 months"), (4, "End of semester")], id: \.0) { months, label in
                                        let date = Calendar.current.date(byAdding: .month, value: months, to: .now) ?? .now
                                        let on = Calendar.current.isDate(date, inSameDayAs: revealDate)
                                        Button(label) { revealDate = date }
                                            .font(.system(size: 13, weight: .medium))
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.08)))
                                            .foregroundStyle(on ? Color(hex: 0x0B1316) : .white)
                                    }
                                }
                                DatePicker("Opens", selection: $revealDate, in: Date.now..., displayedComponents: .date)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(hex: 0x8B9C9F))
                                wideButton("Start group") { launch() }
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Text(gather?.liveName.isEmpty == false ? gather!.liveName : placeholderName)
                        .font(.display(26))
                        .foregroundStyle(.white.opacity(gather?.liveName.isEmpty == false ? 1 : 0.3))
                        .padding(.bottom, 20)
                }
            }

            Button("Invite with a link instead") { inviteManually() }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.vertical, 14)
                .padding(.bottom, 12)
        }
        .animation(.spring(duration: 0.5), value: arrived)
    }

    private var placeholderName: String {
        guard let first = arrived.first else { return "Name your group" }
        return "\(first) & \(myName.trimmingCharacters(in: .whitespaces).isEmpty ? "you" : myName.trimmingCharacters(in: .whitespaces))"
    }

    /// You in the middle; friends settle around you, entering from the edge their phone touched.
    private func ring(in size: CGSize) -> some View {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let n = arrived.count
        return ZStack {
            Circle().stroke(.white.opacity(0.07), lineWidth: 1)
                .frame(width: size.width * 0.72, height: size.width * 0.72)
                .position(c)
            WaveRing(trigger: wave, from: bumpSide, color: Color(hex: color(for: arrived.last ?? "")))
            member(store.state.me.isEmpty ? myName : store.state.me, isMe: true)
                .position(merging ? c : c)
            ForEach(Array(arrived.enumerated()), id: \.element) { k, name in
                member(name, isMe: false)
                    .position(merging ? c : seat(k, of: n, in: size))
                    .opacity(merging ? 0 : 1)
                    .transition(.asymmetric(insertion: entry(in: size), removal: .opacity))
            }
        }
    }

    private func seat(_ k: Int, of n: Int, in size: CGSize) -> CGPoint {
        let spread = n == 1 ? 0 : Double(k) * 2 * .pi / Double(n)
        let a = -Double.pi / 2 + spread + (n == 2 ? -Double.pi / 2 : 0)
        return CGPoint(x: size.width / 2 + cos(a) * size.width * 0.33, y: size.height / 2 + sin(a) * size.height * 0.36)
    }

    private func entry(in size: CGSize) -> AnyTransition {
        let dx: CGFloat = bumpSide == .leading ? -size.width * 0.6 : (bumpSide == .trailing ? size.width * 0.6 : 0)
        let dy: CGFloat = bumpSide == .bottom ? size.height * 0.6 : (bumpSide == .top ? -size.height * 0.6 : 0)
        return AnyTransition.offset(x: dx, y: dy).combined(with: .opacity)
    }

    private func member(_ name: String, isMe: Bool) -> some View {
        let s: CGFloat = isMe ? 74 : 56
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color(hex: color(for: name)).opacity(0.5)).frame(width: s * 2, height: s * 2).blur(radius: 30)
                Avatar(name: name, size: s)
            }
            .frame(width: s, height: s)
            Text(isMe ? "you" : name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
        }
    }

    private func color(for name: String) -> UInt32 {
        if name == store.state.me || name == myName { return myColor }
        let i = name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colors.count
        return Self.colors[i]
    }

    private func bump(_ name: String) {
        bumpSide = [.leading, .trailing, .bottom].randomElement() ?? .leading
        wave += 1
        withAnimation(.spring(duration: 0.6, bounce: 0.3)) { arrived.append(name) }
        // The thunk: a low knock and a rising note.
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        AudioServicesPlaySystemSound(1306)
    }

    private func launch() {
        let id = UUID()
        let name = groupName.trimmingCharacters(in: .whitespaces).isEmpty ? placeholderName : groupName.trimmingCharacters(in: .whitespaces)
        let members = gather?.seal(rollID: id, name: name, revealDate: revealDate, noticeTogether: false) ?? [store.state.me]
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 1)) { merging = true }
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            store.startRoll(id: id, name: name, members: members, revealDate: revealDate)
            gather?.stop()
            onDone?()
        }
    }

    private func inviteManually() {
        gather?.stop()
        step = .share
    }

    /// Link path: the group starts once they've picked when it opens.
    private func makeLink() {
        let id = UUID()
        let name = groupName.trimmingCharacters(in: .whitespaces).isEmpty ? "\(store.state.me)'s group" : groupName.trimmingCharacters(in: .whitespaces)
        store.startRoll(id: id, name: name, members: [store.state.me], revealDate: revealDate)
        withAnimation(.easeInOut(duration: 0.4)) { sealedLink = store.inviteLink }
    }

    // MARK: Share (invite with a link)

    private var shareView: some View {
        VStack(spacing: 20) {
            Spacer()
            if sealedLink == nil {
                question("when do you open it?")
                help("Everything stays sealed until then.")
                revealChips
                DatePicker("Opens", selection: $revealDate, in: Date.now..., displayedComponents: .date)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0x8B9C9F))
                    .padding(.horizontal, 24)
                wideButton("Make the invite link") { makeLink() }
                    .padding(.horizontal, 24)
            } else {
                question("send it to your people")
                help("Anyone with the link can join.")
            }
            if let sealedLink {
                ShareLink(item: sealedLink, message: Text("Join our group on Presents. Everything stays sealed until we open it together.")) {
                    Text("Share invite link")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(hex: 0x0B1316))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Color(hex: 0xF6F7F4)))
                }
                .padding(.horizontal, 24)
            }
            Spacer()
            Button("Done") { onDone?() }
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 40)
        }
    }

    // MARK: Pieces

    private var revealChips: some View {
        HStack(spacing: 8) {
            ForEach([(1, "1 month"), (2, "2 months"), (4, "End of semester")], id: \.0) { months, label in
                let date = Calendar.current.date(byAdding: .month, value: months, to: .now) ?? .now
                let on = Calendar.current.isDate(date, inSameDayAs: revealDate)
                Button(label) { revealDate = date }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.08)))
                    .foregroundStyle(on ? Color(hex: 0x0B1316) : .white)
            }
        }
    }

    private func question(_ text: String) -> some View {
        Text(text).font(.displayItalic(36)).foregroundStyle(Color(hex: 0xF3F5F2))
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(Color(hex: 0x8B9C9F))
    }

    private func wideButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(hex: 0x0B1316))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(Color(hex: 0xF6F7F4)))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func click() {
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func startGathering() {
        if gather == nil {
            let session = GatherSession(name: store.state.me, avatar: store.state.avatars?[store.state.me])
            session.start()
            gather = session
        }
        step = .group
    }

    private func saveFriendPhotos() {
        guard let people = gather?.people else { return }
        var avatars = store.state.avatars ?? [:]
        for (name, data) in people { if let data { avatars[name] = data } }
        if avatars != (store.state.avatars ?? [:]) { store.state.avatars = avatars }
    }
}

/// The colored wave that runs in from the side a friend's phone touched.
struct WaveRing: View {
    var trigger: Int
    var from: Edge
    var color: Color
    @State private var go = false

    var body: some View {
        GeometryReader { geo in
            let origin: CGPoint = switch from {
            case .leading: CGPoint(x: 0, y: geo.size.height / 2)
            case .trailing: CGPoint(x: geo.size.width, y: geo.size.height / 2)
            case .top: CGPoint(x: geo.size.width / 2, y: 0)
            case .bottom: CGPoint(x: geo.size.width / 2, y: geo.size.height)
            }
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.6), color.opacity(0)], center: .center, startRadius: 0, endRadius: 200))
                .frame(width: 400, height: 400)
                .scaleEffect(go ? 1.6 : 0.1)
                .opacity(go ? 0 : (trigger == 0 ? 0 : 0.9))
                .position(origin)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            go = false
            withAnimation(.easeOut(duration: 1.1)) { go = true }
        }
    }
}
