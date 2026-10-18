import SwiftUI

/// Small rounded square used in "My moments" and the archive grid.
struct MomentThumb: View {
    var moment: Moment
    @Environment(RollStore.self) private var store

    var body: some View {
        ZStack {
            switch moment.kind {
            case .photo, .doodle:
                if let image = store.image(for: moment) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Palette.peach
                }
            case .video:
                if let image = store.image(for: moment) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Palette.lilac
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            case .voice:
                LinearGradient(colors: [Palette.lilac, Palette.sky], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "waveform").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
            case .word:
                moment.kind.orbColor
                GrainOverlay().opacity(0.9)
                Text(moment.text)
                    .font(.display(16))
                    .minimumScaleFactor(0.6)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .padding(6)
            case .note:
                Palette.paper
                Text(moment.text)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(Palette.ink)
        .blur(radius: moment.hiddenAt != nil ? 18 : 0)
        .overlay { if moment.hiddenAt != nil { Image(systemName: "eye.slash").foregroundStyle(Palette.ink) } }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
    }
}

/// One moment as a glass sheet card: who saved it, the moment, caption, reactions.
struct MomentCard: View {
    var moment: Moment
    var rollID: UUID
    var kenBurns = false
    var isPlayingVoice = false
    var autoplayVideo = true
    var page: (index: Int, count: Int)?
    var onVideoEnd: (() -> Void)?

    @Environment(RollStore.self) private var store
    @State private var zoom = false

    var body: some View {
        GlassCard(padding: 18, radius: 34) {
            VStack(spacing: 14) {
                Capsule().fill(Palette.secondary.opacity(0.3)).frame(width: 36, height: 5)

                HStack(spacing: 10) {
                    Avatar(name: moment.author, size: 32)
                    Text(moment.author).font(.display(20))
                    Spacer()
                    Text(moment.createdAt.short).font(.tag(12)).foregroundStyle(Palette.secondary)
                }

                media
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 360)

                if !moment.caption.isEmpty {
                    Text(moment.caption)
                        .font(.copy(15))
                        .foregroundStyle(Palette.ink.opacity(0.8))
                        .multilineTextAlignment(.center)
                }

                if let page, page.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<min(page.count, 12), id: \.self) { i in
                            Circle()
                                .fill(i == min(page.index, 11) ? Palette.accent : Palette.secondary.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                }

                ReactionBar(momentID: moment.id, rollID: rollID)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 16)
        .onAppear {
            guard kenBurns else { return }
            withAnimation(.easeOut(duration: 6)) { zoom = true }
        }
    }

    @ViewBuilder private var media: some View {
        switch moment.kind {
        case .photo, .doodle:
            if let image = store.image(for: moment) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom ? 1.05 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        case .video:
            if let url = store.mediaURL(moment) {
                let poster = store.image(for: moment)
                VideoClip(url: url, autoplay: autoplayVideo, onEnd: onVideoEnd)
                    .aspectRatio(poster.map { $0.size.width / max($0.size.height, 1) } ?? 3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        case .voice:
            VStack(spacing: 12) {
                RollOrb(fill: isPlayingVoice ? 1 : 0.6)
                    .frame(width: 170, height: 170)
                    .overlay(Image(systemName: "waveform").font(.system(size: 36, weight: .medium)).foregroundStyle(.white))
                TagLabel(isPlayingVoice ? "Playing voice memo" : "Voice memo")
            }
            .padding(.vertical, 8)
        case .word:
            Text(moment.text)
                .font(.display(44))
                .minimumScaleFactor(0.5)
                .lineLimit(4)
                .multilineTextAlignment(.center)
                .padding(.vertical, 50)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.fill))
        case .note:
            Text(moment.text)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(22)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.fill))
        }
    }
}

/// Emoji reactions under a revealed moment: counts, quick picks, who reacted.
struct ReactionBar: View {
    var momentID: UUID
    var rollID: UUID
    @Environment(RollStore.self) private var store
    @State private var showWho = false
    @State private var burst: String?

    var body: some View {
        let moment = store.moment(momentID, in: rollID)
        let mine = Set((moment?.reactions ?? [:]).filter { $0.value.contains(store.state.me) }.keys)

        VStack(spacing: 10) {
            if let counts = moment?.reactionCounts, !counts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(counts, id: \.emoji) { item in
                            HStack(spacing: 4) {
                                Text(item.emoji)
                                Text("\(item.count)").font(.tag(13)).foregroundStyle(Palette.ink.opacity(0.7))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Palette.fill))
                            .overlay(Capsule().stroke(mine.contains(item.emoji) ? Palette.accent : .clear, lineWidth: 1.5))
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                ForEach(Moment.reactionChoices, id: \.self) { emoji in
                    Button {
                        withAnimation(.spring(duration: 0.35)) {
                            store.toggleReaction(emoji, momentID: momentID, rollID: rollID)
                            burst = emoji
                        }
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            withAnimation { burst = nil }
                        }
                    } label: {
                        Text(emoji)
                            .font(.system(size: 24))
                            .frame(width: 40, height: 40)
                            .scaleEffect(burst == emoji ? 1.35 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.fill))

            if let moment, moment.reactionTotal > 0 {
                Button {
                    withAnimation { showWho.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.3.fill").font(.system(size: 13)).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(moment.reactionTotal == 1 ? "1 reaction" : "\(moment.reactionTotal) reactions").font(.tag(14))
                            Text("Tap to see who reacted").font(.copy(11)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        Image(systemName: showWho ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.fill))
                }
                .buttonStyle(.plain)

                if showWho {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach((moment.reactions ?? [:]).sorted { $0.key < $1.key }, id: \.key) { emoji, people in
                            Text("\(emoji)  \(people.joined(separator: ", "))").font(.copy(13))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}

/// Moments piled up like loose prints, blurred so nothing can be made out before the reveal.
struct SealedStack: View {
    /// Newest first.
    var moments: [Moment]
    @Environment(RollStore.self) private var store

    private struct Slot { var x: CGFloat; var y: CGFloat; var angle: Double; var w: CGFloat; var h: CGFloat }
    private let slots: [Slot] = [
        Slot(x: 5, y: -78, angle: 0, w: 175, h: 105),
        Slot(x: -88, y: -4, angle: -5, w: 128, h: 168),
        Slot(x: 92, y: -10, angle: 6, w: 132, h: 172),
        Slot(x: -58, y: 38, angle: 0, w: 118, h: 118),
        Slot(x: 32, y: 44, angle: 2, w: 148, h: 158),
    ]

    var body: some View {
        ZStack {
            ForEach(0..<slots.count, id: \.self) { i in
                // Oldest at the back, newest on top.
                let index = slots.count - 1 - i
                let moment = index < moments.count ? moments[index] : nil
                tile(moment, slot: slots[i], seed: i)
                    .rotationEffect(.degrees(slots[i].angle))
                    .offset(x: slots[i].x, y: slots[i].y)
            }
        }
        .saturation(0.85)
        .brightness(-0.08)
        .blur(radius: 9)
        .overlay(GrainOverlay().opacity(0.6).blendMode(.overlay))
        .allowsHitTesting(false)
    }

    @ViewBuilder private func tile(_ moment: Moment?, slot: Slot, seed: Int) -> some View {
        switch moment?.kind {
        case .voice:
            Circle()
                .fill(Palette.sky)
                .frame(width: min(slot.w, slot.h), height: min(slot.w, slot.h))
                .overlay(Image(systemName: "waveform").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.backgroundTop.opacity(0.8)))
        case .photo, .video, .doodle:
            if let moment, let image = store.image(for: moment) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: slot.w, height: slot.h)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 10)
            } else {
                placeholder(slot: slot, seed: seed)
            }
        case .note, .word:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.62))
                .frame(width: slot.w, height: slot.h)
                .overlay(alignment: .topLeading) {
                    Text(moment?.text ?? "").font(.system(size: 14, weight: .medium)).foregroundStyle(.black.opacity(0.7)).padding(12)
                }
        case nil:
            placeholder(slot: slot, seed: seed)
        }
    }

    private func placeholder(slot: Slot, seed: Int) -> some View {
        let kinds = MomentKind.capturable
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(kinds[seed % kinds.count].orbColor.opacity(0.5))
            .frame(width: slot.w, height: slot.h)
    }
}
