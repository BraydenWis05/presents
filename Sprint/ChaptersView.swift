import SwiftUI

/// Past chapters, kept to revisit. Quiet UI: people's stuff is the star, hairlines instead of cards.
struct ChaptersView: View {
    @Environment(RollStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Chapters")
                        .font(.display(44))
                        .foregroundStyle(Palette.ink)
                        .padding(.top, 8)
                        .padding(.bottom, 20)

                    if store.chapters.isEmpty {
                        empty
                    } else {
                        ForEach(store.chapters) { roll in
                            NavigationLink(value: roll.id) {
                                ChapterRow(roll: roll)
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(Palette.stroke).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .background(AppBackground())
            .navigationDestination(for: UUID.self) { ArchiveView(rollID: $0) }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            FiveDotMark(mono: true).frame(width: 40, height: 40).opacity(0.5)
            Text("Nothing kept yet.")
                .font(.displayItalic(26))
                .foregroundStyle(Palette.ink)
            if let roll = store.activeRoll {
                Text("\(roll.name) opens \(roll.revealDate.stamp).")
                    .font(.copy(14))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

/// One kept chapter: a collage cover, its name, when it ran and what's in it.
struct ChapterRow: View {
    var roll: Roll

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ChapterCover(roll: roll)
                .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 6) {
                Text(roll.name)
                    .font(.display(28))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(RevealCompiler.dateRange(roll.createdAt, roll.revealedAt ?? roll.revealDate))
                    .font(.copy(13))
                    .foregroundStyle(Palette.secondary)
                Text(RevealCompiler.counts(RevealCompiler.items(for: roll)))
                    .font(.copy(12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: -6) {
                    ForEach(roll.members.prefix(6), id: \.self) { Avatar(name: $0, size: 22) }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.secondary)
        }
        .padding(.vertical, 18)
        .contentShape(Rectangle())
    }
}

/// Up to four moments, loosely piled like prints.
struct ChapterCover: View {
    var roll: Roll

    private var picks: [Moment] {
        let visible = roll.moments.filter { $0.hiddenAt == nil }
        let pictures = visible.filter { [.photo, .video, .doodle].contains($0.kind) }
        return Array((pictures + visible.filter { !pictures.contains($0) }).prefix(4))
    }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let spots: [(CGFloat, CGFloat, Double)] = [(0.36, 0.38, -6), (0.64, 0.4, 5), (0.4, 0.66, 3), (0.62, 0.64, -4)]
            ZStack {
                if picks.isEmpty {
                    RoundedRectangle(cornerRadius: 6).fill(Palette.fill)
                }
                ForEach(Array(picks.enumerated()), id: \.element.id) { i, m in
                    Tile(moment: m)
                        .frame(width: s * 0.56, height: s * 0.56)
                        .rotationEffect(.degrees(spots[i].2))
                        .position(x: spots[i].0 * s, y: spots[i].1 * s)
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                }
            }
        }
    }
}

/// A square moment tile that always fills and clips to its frame.
struct Tile: View {
    var moment: Moment
    var corner: CGFloat = 4
    @Environment(RollStore.self) private var store

    var body: some View {
        Color.clear
            .overlay {
                switch moment.kind {
                case .photo, .video, .doodle:
                    if let image = store.image(for: moment) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        moment.kind.orbColor.opacity(0.6)
                    }
                case .voice:
                    ZStack {
                        moment.kind.orbColor
                        Image(systemName: "waveform").font(.system(size: 18, weight: .light)).foregroundStyle(.white)
                    }
                case .word, .note:
                    ZStack {
                        moment.kind.orbColor
                        GrainOverlay().opacity(0.9)
                        Text(moment.text)
                            .font(.display(15))
                            .foregroundStyle(Color(hex: 0x0B1316))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.5)
                            .padding(6)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if moment.kind == .video {
                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.white).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .blur(radius: moment.hiddenAt != nil ? 14 : 0)
            .overlay {
                if moment.hiddenAt != nil {
                    Image(systemName: "eye.slash").font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.8))
                }
            }
    }
}

/// A kept chapter: everything, by day and time, to browse and add what you remember.
struct ArchiveView: View {
    var rollID: UUID
    @Environment(RollStore.self) private var store
    @State private var replaying = false
    @State private var showNewRoll = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    private struct Day: Identifiable {
        var id: Date { start }
        var start: Date
        var moments: [Moment]
    }

    private func days(_ roll: Roll) -> [Day] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: roll.revealOrder) { cal.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted().map { Day(start: $0, moments: grouped[$0] ?? []) }
    }

    var body: some View {
        if let roll = store.roll(rollID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(roll)

                    ForEach(days(roll)) { day in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(day.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                .font(.displayItalic(22))
                                .foregroundStyle(Palette.ink)
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(day.moments) { moment in
                                    if moment.hiddenAt == nil {
                                        NavigationLink {
                                            MomentDetailView(rollID: roll.id, momentID: moment.id)
                                        } label: {
                                            cell(moment)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        // Hidden at the reveal: sealed again.
                                        cell(moment)
                                    }
                                }
                            }
                        }
                        .padding(.top, 28)
                    }

                    if store.activeRoll == nil {
                        Button("Start the next chapter") { showNewRoll = true }
                            .font(.copy(15))
                            .foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .background(AppBackground())
            .fullScreenCover(isPresented: $replaying) {
                PresentationNight(roll: roll) { replaying = false }
            }
            .sheet(isPresented: $showNewRoll) {
                StartRollView { showNewRoll = false }
            }
        }
    }

    private func header(_ roll: Roll) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(roll.name)
                .font(.display(44))
                .foregroundStyle(Palette.ink)
            Text(RevealCompiler.dateRange(roll.createdAt, roll.revealedAt ?? roll.revealDate))
                .font(.copy(14))
                .foregroundStyle(Palette.secondary)
            Text(RevealCompiler.counts(RevealCompiler.items(for: roll)))
                .font(.copy(13))
                .foregroundStyle(Palette.secondary)
            HStack(spacing: -6) {
                ForEach(roll.members, id: \.self) { Avatar(name: $0, size: 28) }
            }
            .padding(.top, 4)
            Button("Play it again") { replaying = true }
                .buttonStyle(.pill)
                .padding(.top, 14)
        }
        .padding(.top, 4)
    }

    private func cell(_ moment: Moment) -> some View {
        Tile(moment: moment, corner: 6)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Text(RevealCompiler.time(moment.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(5)
            }
            .overlay(alignment: .topTrailing) {
                if !moment.reflections.isEmpty {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(6)
                }
            }
    }
}

/// One moment, big, with what the group remembers about it.
struct MomentDetailView: View {
    var rollID: UUID
    var momentID: UUID
    @Environment(RollStore.self) private var store
    @State private var draft = ""

    var body: some View {
        if let moment = store.roll(rollID)?.moments.first(where: { $0.id == momentID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    media(moment)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(moment.createdAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                            .font(.copy(13))
                            .foregroundStyle(Palette.secondary)
                        if !moment.caption.isEmpty {
                            Text(moment.caption).font(.displayItalic(24)).foregroundStyle(Palette.ink)
                        }
                    }

                    Rectangle().fill(Palette.stroke).frame(height: 1)

                    Text("what we remember")
                        .font(.displayItalic(22))
                        .foregroundStyle(Palette.ink)
                    ForEach(moment.reflections) { r in
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(name: r.author, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.text).font(.copy(15)).foregroundStyle(Palette.ink)
                                Text(r.createdAt.short).font(.copy(11)).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("", text: $draft, prompt: Text("Add what you remember").foregroundStyle(Palette.secondary), axis: .vertical)
                            .font(.copy(15))
                            .foregroundStyle(Palette.ink)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Rectangle().fill(Palette.stroke).frame(height: 1) }
                        Button("Add") {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            store.addReflection(text, to: momentID, in: rollID)
                            draft = ""
                        }
                        .font(.copy(15).weight(.medium))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Palette.secondary : Palette.ink)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .background(AppBackground())
            .keyboardDoneButton()
        }
    }

    @ViewBuilder private func media(_ moment: Moment) -> some View {
        switch moment.kind {
        case .photo, .doodle:
            if let image = store.image(for: moment) {
                Image(uiImage: image).resizable().scaledToFit()
            }
        case .video:
            if let url = store.mediaURL(moment) {
                VideoClip(url: url, autoplay: false)
                    .aspectRatio(store.image(for: moment).map { $0.size.width / max($0.size.height, 1) } ?? 3 / 4, contentMode: .fit)
            }
        case .voice:
            VStack(spacing: 16) {
                Image(systemName: "waveform").font(.system(size: 44, weight: .light)).foregroundStyle(.white)
                if let url = store.mediaURL(moment) { VoicePlayButton(url: url) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
            .background(moment.kind.orbColor.opacity(0.35))
        case .word, .note:
            Text(moment.text)
                .font(.display(38))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .padding(.horizontal, 24)
                .background(ZStack { moment.kind.orbColor.opacity(0.3); GrainOverlay().opacity(0.9) })
        }
    }
}

struct VoicePlayButton: View {
    var url: URL
    @State private var player = ClipPlayer()

    var body: some View {
        Button(player.isPlaying ? "Stop" : "Play voice note") {
            player.isPlaying ? player.stop() : player.play(url)
        }
        .buttonStyle(.pill)
        .onDisappear { player.stop() }
    }
}
