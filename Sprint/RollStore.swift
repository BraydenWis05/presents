import Foundation
import UIKit
import SwiftUI
import WidgetKit

struct AppState: Codable {
    var me: String = ""
    var phone: String?
    /// Profile photos by name (small JPEGs): yours, and friends' from setup.
    var avatars: [String: Data]?
    var rolls: [Roll] = []
    var presencePromptsOn = false
}

/// Local, single-device store. Hidden-until-reveal is only enforced in the UI here;
/// once group sync exists it must be enforced on the server.
@Observable
final class RollStore {
    var state: AppState { didSet { save(); refreshWidget() } }

    /// Transient: drives the capture sheet from anywhere in the app.
    var captureRequest: CaptureRequest?

    /// Transient: roll members physically nearby right now (from PresenceMonitor).
    var togetherNow: [String] = [] {
        didSet { if togetherNow != oldValue { refreshWidget() } }
    }

    @ObservationIgnored private var imageCache: [String: UIImage] = [:]

    private static var documents: URL { URL.documentsDirectory }
    private static var stateURL: URL { documents.appending(path: "presents.json") }
    static var mediaFolder: URL {
        let url = documents.appending(path: "media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            state = decoded
        } else {
            state = AppState()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    // MARK: Rolls

    var activeIndex: Int? { state.rolls.firstIndex { !$0.isRevealed } }
    var activeRoll: Roll? { activeIndex.map { state.rolls[$0] } }

    var chapters: [Roll] {
        state.rolls.filter(\.isRevealed)
            .sorted { ($0.revealedAt ?? .distantPast) > ($1.revealedAt ?? .distantPast) }
    }

    func roll(_ id: UUID) -> Roll? { state.rolls.first { $0.id == id } }

    /// The host seals the roll after everyone joined in person.
    func startRoll(id: UUID, name: String, members: [String], revealDate: Date) {
        state.rolls.append(Roll(id: id, name: name, members: members, revealDate: revealDate))
    }

    /// A guest receives the same roll from the host's phone, or from an invite link.
    func joinRoll(_ invite: RollInvite) {
        guard roll(invite.rollID) == nil else { return }
        var members = invite.members
        if !members.contains(state.me) { members.append(state.me) }
        state.rolls.append(Roll(id: invite.rollID, name: invite.name, members: members, revealDate: invite.revealDate))
        state.presencePromptsOn = invite.noticeTogether
    }

    /// An invite link for the active roll, to bring someone in after setup.
    var inviteLink: URL? {
        guard let roll = activeRoll else { return nil }
        return RollInvite(rollID: roll.id, name: roll.name, revealDate: roll.revealDate, members: roll.members,
                          noticeTogether: state.presencePromptsOn).link
    }

    /// An invite opened from a link, waiting for the person to confirm.
    var pendingInvite: RollInvite?

    func updateActive(_ change: (inout Roll) -> Void) {
        guard let i = activeIndex else { return }
        change(&state.rolls[i])
    }

    func reveal() {
        updateActive { $0.revealedAt = .now }
    }

    /// Step out of the current roll on this phone.
    func leaveActiveRoll() {
        guard let i = activeIndex else { return }
        state.rolls.remove(at: i)
    }

    /// Wipe this phone: profile, rolls, chapters and media.
    func eraseEverything() {
        try? FileManager.default.removeItem(at: Self.mediaFolder)
        imageCache = [:]
        state = AppState()
    }

    /// A guest whose phone joined reveal night: the roll is open for them too.
    func markRevealed(_ rollID: UUID) {
        guard let i = state.rolls.firstIndex(where: { $0.id == rollID }), state.rolls[i].revealedAt == nil else { return }
        state.rolls[i].revealedAt = .now
    }

    // MARK: Moments

    func saveMoment(kind: MomentKind, caption: String, text: String = "", image: UIImage?, audio: URL?, video: URL? = nil, videoThumb: UIImage? = nil) {
        var moment = Moment(author: state.me, kind: kind, caption: caption, text: text)
        if kind == .doodle, let image, let data = image.pngData() {
            let name = "\(moment.id).png"
            try? data.write(to: Self.mediaFolder.appending(path: name))
            moment.mediaFile = name
        } else if let image, let data = image.downscaled(maxSide: 2000).jpegData(compressionQuality: 0.8) {
            let name = "\(moment.id).jpg"
            try? data.write(to: Self.mediaFolder.appending(path: name))
            moment.mediaFile = name
        }
        if let audio {
            let name = "\(moment.id).m4a"
            try? FileManager.default.moveItem(at: audio, to: Self.mediaFolder.appending(path: name))
            moment.mediaFile = name
        }
        if let video {
            let name = "\(moment.id).\(video.pathExtension.isEmpty ? "mov" : video.pathExtension)"
            try? FileManager.default.moveItem(at: video, to: Self.mediaFolder.appending(path: name))
            moment.mediaFile = name
            if let data = videoThumb?.downscaled(maxSide: 800).jpegData(compressionQuality: 0.8) {
                try? data.write(to: Self.mediaFolder.appending(path: Self.thumbName(moment.id)))
            }
        }
        updateActive { $0.moments.append(moment) }
    }

    private static func thumbName(_ id: UUID) -> String { "\(id).thumb.jpg" }

    func addReflection(_ text: String, to momentID: UUID, in rollID: UUID) {
        guard let r = state.rolls.firstIndex(where: { $0.id == rollID }),
              let m = state.rolls[r].moments.firstIndex(where: { $0.id == momentID }) else { return }
        state.rolls[r].moments[m].reflections.append(Reflection(author: state.me, text: text))
    }

    func toggleReaction(_ emoji: String, momentID: UUID, rollID: UUID) {
        guard let r = state.rolls.firstIndex(where: { $0.id == rollID }),
              let m = state.rolls[r].moments.firstIndex(where: { $0.id == momentID }) else { return }
        var reactions = state.rolls[r].moments[m].reactions ?? [:]
        var people = reactions[emoji] ?? []
        if let i = people.firstIndex(of: state.me) { people.remove(at: i) } else { people.append(state.me) }
        reactions[emoji] = people.isEmpty ? nil : people
        state.rolls[r].moments[m].reactions = reactions
    }

    /// A reaction sent from a friend's phone during presentation night.
    func addReaction(_ emoji: String, by person: String, momentID: UUID, rollID: UUID) {
        guard let r = state.rolls.firstIndex(where: { $0.id == rollID }),
              let m = state.rolls[r].moments.firstIndex(where: { $0.id == momentID }) else { return }
        var reactions = state.rolls[r].moments[m].reactions ?? [:]
        var people = reactions[emoji] ?? []
        if !people.contains(person) { people.append(person) }
        reactions[emoji] = people
        state.rolls[r].moments[m].reactions = reactions
    }

    /// Hidden during the reveal. It stays sealed again in the archive.
    func hideMoment(_ momentID: UUID, in rollID: UUID?) {
        for r in state.rolls.indices where rollID == nil || state.rolls[r].id == rollID {
            if let m = state.rolls[r].moments.firstIndex(where: { $0.id == momentID }), state.rolls[r].moments[m].hiddenAt == nil {
                state.rolls[r].moments[m].hiddenAt = .now
            }
        }
    }

    /// Take back your own save before the reveal opens. Blind: you never see it again.
    func takeBack(_ moment: Moment) {
        guard moment.author == state.me, activeRoll?.isRevealed == false else { return }
        updateActive { $0.moments.removeAll { $0.id == moment.id } }
        if let file = moment.mediaFile {
            try? FileManager.default.removeItem(at: Self.mediaFolder.appending(path: file))
        }
        try? FileManager.default.removeItem(at: Self.mediaFolder.appending(path: Self.thumbName(moment.id)))
    }

    var myTakeBacks: [Moment] {
        (activeRoll?.moments ?? []).filter { $0.author == state.me }.sorted { $0.createdAt > $1.createdAt }
    }

    func moment(_ momentID: UUID, in rollID: UUID) -> Moment? {
        roll(rollID)?.moments.first { $0.id == momentID }
    }

    func mediaURL(_ moment: Moment) -> URL? {
        moment.mediaFile.map { Self.mediaFolder.appending(path: $0) }
    }

    /// The photo itself, or a video's poster frame.
    func image(for moment: Moment) -> UIImage? {
        let file: String
        switch moment.kind {
        case .photo, .doodle:
            guard let name = moment.mediaFile else { return nil }
            file = name
        case .video:
            file = Self.thumbName(moment.id)
        default:
            return nil
        }
        if let cached = imageCache[file] { return cached }
        let image = UIImage(contentsOfFile: Self.mediaFolder.appending(path: file).path())
        imageCache[file] = image
        return image
    }

    // MARK: Widget

    /// Writes what the home screen widget shows: roll info, who's nearby, and a pre-blurred image of the stack.
    func refreshWidget() {
        guard let roll = activeRoll else {
            WidgetSnapshot.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        WidgetSnapshot(
            rollName: roll.name,
            revealDate: roll.revealDate,
            momentCount: roll.moments.count,
            isReadyToOpen: roll.isReadyToOpen,
            togetherWith: togetherNow
        ).save()

        let newestFirst = Array(roll.moments.sorted { $0.createdAt > $1.createdAt }.prefix(5))
        let renderer = ImageRenderer(content:
            SealedStack(moments: newestFirst)
                .environment(self)
                .frame(width: 360, height: 340)
                .background(Palette.backgroundTop)
        )
        renderer.scale = 2
        if let url = WidgetSnapshot.stackImageURL, let data = renderer.uiImage?.pngData() {
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
