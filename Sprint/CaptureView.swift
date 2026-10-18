import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import PencilKit

/// The roll picks the format (see MediaPickerView). No rerolls, no choosing.
/// Once saved, it's sealed, even from whoever added it.
struct CaptureView: View {
    /// Who you're with, when this came from the "document this?" nudge.
    var with: [String] = []

    @Environment(RollStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Nil while the picker is shuffling; set once they tap the action button.
    @State private var started: MomentKind?
    private var kind: MomentKind { started ?? .photo }
    @State private var drawing = PKDrawing()
    @State private var word = ""
    @State private var canvasSide: CGFloat = 340
    static let wordLimit = 50
    @FocusState private var wordFocused: Bool
    @State private var caption = ""
    @State private var image: UIImage?
    @State private var videoURL: URL?
    @State private var videoThumb: UIImage?
    @State private var loadingVideo = false
    @State private var showCamera = false
    @State private var recorder = VoiceRecorder()
    @State private var player = ClipPlayer()
    @State private var saved = false

    private var canSave: Bool {
        switch kind {
        case .photo: image != nil
        case .video: videoURL != nil
        case .voice: recorder.recordedURL != nil && !recorder.isRecording
        case .doodle: !drawing.strokes.isEmpty
        case .word: !word.trimmingCharacters(in: .whitespaces).isEmpty
        case .note: false
        }
    }

    var body: some View {
        ZStack {
            if started == nil {
                MediaPickerView(with: with) { picked in
                    withAnimation(.easeInOut(duration: 0.35)) { started = picked }
                    // Voice starts recording right away: the button said "Record".
                    if picked == .voice { Task { await recorder.start() } }
                    if picked == .photo || picked == .video, UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    }
                }
                .overlay(alignment: .topLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Palette.fill))
                    }
                    .padding(.leading, 20)
                    .padding(.top, 16)
                }
                .transition(.opacity)
            } else {
                captureScreen
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var captureScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 14) {
                        MediaOrb(color: kind.orbColor, size: 54, softness: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            TagLabel(with.isEmpty ? kind.title : "\(kind.title) · with \(Together.names(with))")
                            Text(kind.invitation)
                                .font(.display(28))
                                .foregroundStyle(Palette.ink)
                        }
                    }

                    Group {
                        switch kind {
                        case .photo: photoCapture
                        case .video: videoCapture
                        case .voice: voiceCapture
                        case .doodle: doodleCapture
                        case .word: wordCapture
                        case .note: EmptyView()
                        }
                    }

                    if kind != .word {
                    VStack(alignment: .leading, spacing: 8) {
                        TagLabel("Caption, if you want")
                        TextField("", text: $caption, prompt: Text("say less").foregroundStyle(Palette.secondary))
                            .font(.copy(17))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.fill))
                    }
                    }

                    Text("One take, no redos. Once it's in, it's sealed. Even from you.")
                        .font(.copy(13))
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity)

                    Button("Seal it in", action: save)
                        .buttonStyle(.pill)
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.4)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .keyboardDoneButton()
            .overlay { if saved { savedConfirmation } }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(video: kind == .video, onImage: { image = $0 }, onVideo: { url in
                Task { await setVideo(url) }
            })
            .ignoresSafeArea()
        }
        .onDisappear {
            player.stop()
            if recorder.isRecording { recorder.stop() }
            if !saved {
                recorder.discard()
                if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
            }
        }
    }

    // MARK: Formats

    private var photoCapture: some View {
        VStack(spacing: 14) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .background(Palette.fill)
                    .rotationEffect(.degrees(-1.5))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
                    .frame(maxHeight: 340)
                    .frame(maxWidth: .infinity)
            }
            if image == nil {
                cameraButton("Open camera")
            }
        }
    }

    private var videoCapture: some View {
        VStack(spacing: 14) {
            if let videoURL {
                VideoClip(url: videoURL, autoplay: false)
                    .aspectRatio(videoThumb.map { $0.size.width / max($0.size.height, 1) } ?? 3 / 4, contentMode: .fit)
                    .padding(8)
                    .background(Palette.fill)
                    .rotationEffect(.degrees(1.2))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
                    .frame(maxHeight: 360)
                    .frame(maxWidth: .infinity)
            } else if loadingVideo {
                ProgressView().frame(height: 120).frame(maxWidth: .infinity)
            }
            if videoURL == nil && !loadingVideo {
                cameraButton("Open camera")
                Text("Up to \(Int(CameraPicker.maxVideoLength)) seconds. Shaky is fine.")
                    .font(.tag(11))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    /// Viewfinder only: no camera roll, so what goes in is what's happening now.
    @ViewBuilder private func cameraButton(_ title: String) -> some View {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button(title) { showCamera = true }
                .buttonStyle(.pill)
                .frame(maxWidth: .infinity)
        } else {
            Text("This device has no camera.")
                .font(.copy(14))
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var voiceCapture: some View {
        VStack(spacing: 16) {
            if recorder.recordedURL == nil {
            Button {
                Task { await recorder.toggle() }
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Palette.pink : Palette.ink)
                        .frame(width: 110, height: 110)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Palette.backgroundTop)
                }
                .scaleEffect(recorder.isRecording ? 1.05 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: recorder.isRecording)
            }
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record")
            }

            Text(timeString(recorder.elapsed) + " / " + timeString(VoiceRecorder.maxLength))
                .font(.tag(12))
                .foregroundStyle(Palette.secondary)

            if let url = recorder.recordedURL, !recorder.isRecording {
                Button(player.isPlaying ? "Stop" : "Play it back") {
                    player.isPlaying ? player.stop() : player.play(url)
                }
                .buttonStyle(.frostedPill)
            }
            if recorder.permissionDenied {
                Text("Microphone is off for Presents. Turn it on in Settings to record.")
                    .font(.copy(14))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var doodleCapture: some View {
        VStack(spacing: 12) {
            DoodleCanvas(drawing: $drawing)
                .aspectRatio(1, contentMode: .fit)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasSide = $0 }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("No erasing. Every line stays.")
                .font(.copy(13))
                .foregroundStyle(Palette.secondary)
        }
    }

    private var wordCapture: some View {
        VStack(spacing: 10) {
            TextField("", text: $word, prompt: Text("…").foregroundStyle(Palette.secondary), axis: .vertical)
                .focused($wordFocused)
                .onAppear { Task { try? await Task.sleep(for: .seconds(0.4)); wordFocused = true } }
                .font(.display(40))
                .lineLimit(1...3)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.fill))
                .onChange(of: word) { _, new in
                    // Return closes the keyboard instead of adding a line.
                    if new.contains("\n") { wordFocused = false }
                    let trimmed = String(new.replacingOccurrences(of: "\n", with: "").prefix(Self.wordLimit))
                    if trimmed != new { word = trimmed }
                }
            Text("\(Self.wordLimit - word.count) left")
                .font(.copy(13))
                .foregroundStyle(Palette.secondary)
        }
    }

    private var savedConfirmation: some View {
        ZStack {
            AppBackground(intense: true)
            Sparkles(count: 12)
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Palette.accent)
                Text("It's in the roll.")
                    .font(.display(40))
                TagLabel("You'll see it on reveal night, with everyone")
            }
            .foregroundStyle(Palette.ink)
        }
        .transition(.opacity)
    }

    // MARK: Actions

    private func setVideo(_ url: URL) async {
        if let old = videoURL, old != url { try? FileManager.default.removeItem(at: old) }
        videoURL = url
        videoThumb = await posterFrame(for: url)
    }

    private func save() {
        player.stop()
        store.saveMoment(
            kind: kind,
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            text: kind == .word ? word.trimmingCharacters(in: .whitespaces) : "",
            image: kind == .photo ? image : (kind == .doodle ? DoodleCanvas.render(drawing, side: drawingSide) : nil),
            audio: kind == .voice ? recorder.recordedURL : nil,
            video: kind == .video ? videoURL : nil,
            videoThumb: videoThumb
        )
        withAnimation(.easeIn(duration: 0.25)) { saved = true }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            dismiss()
        }
    }

    /// The whole square canvas, so the doodle keeps its placement.
    private var drawingSide: CGFloat { canvasSide }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "0:%02d", Int(t.rounded(.down)))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    static let maxVideoLength: TimeInterval = 15

    var video = false
    var onImage: (UIImage) -> Void = { _ in }
    var onVideo: (URL) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if video {
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoMaximumDuration = Self.maxVideoLength
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                // The picker's file is temporary; keep our own copy.
                let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(url.pathExtension)")
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { parent.onVideo(copy) }
            } else if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// A video picked from the camera roll, copied somewhere we own.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

func posterFrame(for url: URL) async -> UIImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    guard let frame = try? await generator.image(at: .zero) else { return nil }
    return UIImage(cgImage: frame.image)
}
