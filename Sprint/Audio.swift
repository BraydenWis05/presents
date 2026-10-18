import AVFoundation
import AVKit
import SwiftUI

/// Plays one clip at a time (voice memo previews and the reveal).
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private var player: AVAudioPlayer?

    func play(_ url: URL) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        isPlaying = player?.play() ?? false
        if !isPlaying { onFinish?() }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.onFinish?()
        }
    }
}

/// Records short voice memos, capped so clips stay small and casual.
@Observable
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    static let maxLength: TimeInterval = 30

    var isRecording = false
    var elapsed: TimeInterval = 0
    var recordedURL: URL?
    var permissionDenied = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var tick: Task<Void, Never>?

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            permissionDenied = true
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)

        discard()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder.delegate = self
        recorder.record(forDuration: Self.maxLength)
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder, recorder.isRecording else { break }
                self.elapsed = recorder.currentTime
            }
        }
    }

    func stop() {
        recorder?.stop()
    }

    func discard() {
        if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
        recordedURL = nil
        elapsed = 0
    }

    private func finish(success: Bool) {
        tick?.cancel()
        isRecording = false
        if success, let url = recorder?.url { recordedURL = url }
        recorder = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finish(success: flag) }
    }
}

/// Plays one video clip with sound. Tells the reveal when it ends so the mini-movie can move on.
struct VideoClip: View {
    var url: URL
    var autoplay = true
    var onEnd: (() -> Void)?
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let player = AVPlayer(url: url)
                self.player = player
                if autoplay { player.play() }
            }
            .onDisappear { player?.pause() }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
                guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
                onEnd?()
            }
    }
}
