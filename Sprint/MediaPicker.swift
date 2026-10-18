import SwiftUI
import PencilKit
import AudioToolbox

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension MomentKind {
    /// Thin line icon shown in the blob and on the result.
    var lineIcon: String {
        switch self {
        case .video: "video"
        case .doodle: "pencil"
        case .photo: "camera"
        case .voice: "waveform"
        case .word, .note: "line.3.horizontal"
        }
    }

    /// The short line under the result title.
    var lines: [String] {
        switch self {
        case .photo: ["Point it at whatever is happening."]
        case .video: ["Ten seconds. No retakes."]
        case .voice: ["Say the thing out loud."]
        case .doodle: ["Bad art strongly encouraged."]
        case .word, .note: ["A few words. Make it an inside joke."]
        }
    }

    /// What the shuffle says when it lands.
    var headline: String {
        switch self {
        case .photo: "A photo!"
        case .video: "A video!"
        case .voice: "A voice note!"
        case .doodle: "Ooh, a doodle."
        case .word, .note: "Words."
        }
    }

    /// Each format has its own color; colors belong to media types, never to people.
    var orbColor: Color {
        switch self {
        // Finley's moment colors (moment-shuffle.html).
        case .video: Color(hex: 0xE2642E)
        case .doodle: Color(hex: 0xBCD3DC)
        case .photo: Color(hex: 0xD257B4)
        case .voice: Color(hex: 0x1A86A6)
        case .word, .note: Color(hex: 0xE5D24A)
        }
    }
}

/// A soft, glowing disc.
struct MediaOrb: View {
    var color: Color
    var size: CGFloat
    var softness: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [color, color.opacity(0.92), color.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: size / 2
            ))
            .frame(width: size, height: size)
            .blur(radius: softness)
    }
}

// MARK: Moment shuffle (ported from Finley's moment-shuffle.html, "pulse" home without the pulsing)

/// Physics for the five blobs: idle (merged glow) → charging → vortex → land → reveal.
@Observable
final class ShuffleEngine {
    enum Mode { case idle, charging, shuffle, land, reveal }

    struct Blob {
        let kind: MomentKind
        let index: Int
        var x: CGFloat = 0, y: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0
        var s: CGFloat = 1, o: CGFloat = 1, blur: CGFloat = 14
        var ang: CGFloat = 0, r0: CGFloat = 0
    }

    var blobs: [Blob] = MomentKind.capturable.enumerated().map { Blob(kind: $1, index: $0) }
    private(set) var mode: Mode = .idle
    private(set) var charge: CGFloat = 0
    private(set) var winner: MomentKind = .photo
    private(set) var showResult = false
    var size: CGSize = .zero { didSet { if oldValue == .zero { placeHome() } } }

    /// Fires a tick (sound + haptic) each time the ring passes a slot.
    @ObservationIgnored var onTick: ((CGFloat) -> Void)?
    @ObservationIgnored var onLand: (() -> Void)?
    @ObservationIgnored private var modeT: CGFloat = 0
    @ObservationIgnored private var intensity: CGFloat = 1
    @ObservationIgnored private var spin: CGFloat = 0
    @ObservationIgnored private var spinAcc: CGFloat = 0
    @ObservationIgnored private var lastWinner: MomentKind?
    @ObservationIgnored private var jitter: [CGPoint] = Array(repeating: .zero, count: 5)

    private var W: CGFloat { size.width }
    private var H: CGFloat { size.height }
    private var cx: CGFloat { W / 2 }
    private var cy: CGFloat { H * 0.47 }
    private let step = CGFloat.pi * 2 / 5

    private func home(_ i: Int) -> CGPoint {
        // Merged into one still glow behind the mark. No breathing.
        let a = -CGFloat.pi / 2 + CGFloat(i) * step
        let r = W * 0.1
        return CGPoint(x: cx + cos(a) * r, y: H * 0.42 + sin(a) * r)
    }

    private func placeHome() {
        for i in blobs.indices { let h = home(i); blobs[i].x = h.x; blobs[i].y = h.y; blobs[i].s = 1.12 }
    }

    // MARK: Input

    func pressDown() {
        guard mode == .idle else { return }
        mode = .charging
        charge = 0
    }

    func release() {
        guard mode == .charging else { return }
        start(power: 1 + charge)
    }

    func cancelCharge() {
        guard mode == .charging else { return }
        mode = .idle
        charge = 0
    }

    func skip() { if mode == .shuffle { enterLand() } }

    func start(power: CGFloat = 1) {
        showResult = false
        mode = .shuffle
        modeT = 0
        intensity = power
        spin = 0
        spinAcc = 0
        charge = 0
        var pick: MomentKind
        repeat { pick = MomentKind.capturable.randomElement() ?? .photo } while pick == lastWinner
        #if DEBUG
        // Testing: launch with `-forceKind voice` to always land on one type.
        if let forced = UserDefaults.standard.string(forKey: "forceKind").flatMap(MomentKind.init(rawValue:)) { pick = forced }
        #endif
        winner = pick
        for i in blobs.indices {
            // Blobs that flew off after the last pick come back in from the edges.
            if blobs[i].o < 0.2 {
                let a = CGFloat.random(in: 0..<(2 * .pi))
                blobs[i].x = cx + cos(a) * W * 0.8
                blobs[i].y = cy + sin(a) * W * 0.8
            }
            blobs[i].ang = atan2(blobs[i].y - cy, blobs[i].x - cx)
            blobs[i].r0 = hypot(blobs[i].x - cx, blobs[i].y - cy)
        }
    }

    private func enterLand() {
        mode = .land
        modeT = 0
        lastWinner = winner
        for i in blobs.indices { blobs[i].vx *= 0.3; blobs[i].vy *= 0.3 }
        onLand?()
    }

    // MARK: Frame

    func update(_ dt: CGFloat) {
        guard W > 0 else { return }
        switch mode {
        case .idle, .charging: updateIdle(dt)
        case .shuffle: modeT += dt; updateVortex(dt)
        case .land, .reveal: modeT += dt; updateLand(dt)
        }
    }

    private func spring(_ i: Int, _ tx: CGFloat, _ ty: CGFloat, _ k: CGFloat, _ dt: CGFloat) {
        let c = 2 * sqrt(k) * 0.72
        for _ in 0..<2 {
            let h = dt / 2
            blobs[i].vx += (k * (tx - blobs[i].x) - c * blobs[i].vx) * h
            blobs[i].vy += (k * (ty - blobs[i].y) - c * blobs[i].vy) * h
            blobs[i].x += blobs[i].vx * h
            blobs[i].y += blobs[i].vy * h
        }
    }

    private func ease(_ i: Int, s: CGFloat, o: CGFloat, blur: CGFloat, _ dt: CGFloat, rate: CGFloat = 7) {
        let f = 1 - exp(-dt * rate)
        blobs[i].s += (s - blobs[i].s) * f
        blobs[i].o += (o - blobs[i].o) * f
        blobs[i].blur += (blur - blobs[i].blur) * f
    }

    private func updateIdle(_ dt: CGFloat) {
        if mode == .charging {
            charge = min(1, charge + dt / 1.1)
            if CGFloat.random(in: 0...1) < charge * 0.15 { onTick?(0.3 + charge * 0.4) }
        }
        for i in blobs.indices {
            let h = home(i)
            var hx = h.x, hy = h.y
            if mode == .charging {
                hx += (cx - hx) * charge * 0.42 + CGFloat.random(in: -0.5...0.5) * charge * 14
                hy += (cy - hy) * charge * 0.42 + CGFloat.random(in: -0.5...0.5) * charge * 14
            }
            spring(i, hx, hy, 26, dt)
            ease(i, s: 1.12 - charge * 0.12, o: 1, blur: 14 + charge * 6, dt, rate: 4)
        }
    }

    private func updateVortex(_ dt: CGFloat) {
        let T = modeT, top = 8 * intensity
        func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
        func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
        let w: CGFloat = T < 0.8 ? top * easeInOut(T / 0.8) : T < 1.5 ? top : top + (0.4 - top) * easeOut(min(max((T - 1.5) / 1.1, 0), 1))
        spin += w * dt
        // Roulette-style clicker: one tick each time the ring turns one slot.
        spinAcc += w * dt
        while spinAcc >= step { spinAcc -= step; onTick?(min(1, 0.5 + w / 16)) }
        let inner = W * 0.12, outer = W * 0.3
        for i in blobs.indices {
            let slot = -CGFloat.pi / 2 + CGFloat(i) * step
            var delta = slot - blobs[i].ang
            delta = atan2(sin(delta), cos(delta))
            let e = easeInOut(min(max(T / 0.8, 0), 1))
            let r: CGFloat = T < 0.8 ? blobs[i].r0 + (inner - blobs[i].r0) * e
                : T < 1.5 ? inner + sin(T * 14 + CGFloat(i)) * 5
                : inner + (outer - inner) * easeOut(min(max((T - 1.5) / 1.1, 0), 1))
            let a = blobs[i].ang + delta * e + spin
            spring(i, cx + cos(a) * r, cy + sin(a) * r, 240, dt)
            let lit = blobs[i].kind == winner && T > 1.9
            ease(i, s: lit ? 0.9 : 0.62, o: lit ? 1 : 0.55, blur: 22, dt)
        }
        if T >= 2.7 { enterLand() }
    }

    /// The picked blob drifts to the middle, grows and goes soft; the rest drift off.
    private func updateLand(_ dt: CGFloat) {
        for i in blobs.indices {
            if blobs[i].kind == winner {
                spring(i, cx, H * 0.41, 40, dt)
                ease(i, s: 2.35, o: 0.62, blur: 40, dt, rate: 2.6)
            } else {
                let dx = blobs[i].x - cx, dy = blobs[i].y - cy, d = max(hypot(dx, dy), 1)
                spring(i, cx + dx / d * W * 0.95, cy + dy / d * W * 0.95, 20, dt)
                ease(i, s: 0.5, o: 0, blur: 30, dt, rate: 4)
            }
        }
        if !showResult && modeT > 0.35 { showResult = true }
        if modeT > 1.6 { mode = .reveal }
    }
}

/// After tapping add: "capture a moment", Shuffle (press and hold to wind it up), the vortex,
/// then the result with one free reroll. You never choose.
struct MediaPickerView: View {
    var with: [String] = []
    /// Called with the format once the person taps Let's go.
    var onStart: (MomentKind) -> Void

    @State private var engine = ShuffleEngine()
    @State private var rerollsLeft = 1
    @State private var line = ""
    @State private var pressing = false
    @State private var last = Date.now
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x0B1B21), location: 0), .init(color: Color(hex: 0x0A171C), location: 0.35),
                    .init(color: Color(hex: 0x0A1518), location: 0.5), .init(color: Color(hex: 0x0A1215), location: 0.8),
                    .init(color: Color(hex: 0x0A1012), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

                TimelineView(.animation) { timeline in
                    blobs
                        .onChange(of: timeline.date) { _, now in
                            engine.update(CGFloat(min(0.033, now.timeIntervalSince(last))))
                            last = now
                        }
                }

                home(in: geo.size)
                shuffling(in: geo.size)
                result(in: geo.size)

                GrainOverlay().opacity(0.8).allowsHitTesting(false).ignoresSafeArea()

            }
            .onAppear {
                engine.size = geo.size
                engine.onTick = { strength in
                    haptic.impactOccurred(intensity: strength)
                    AudioServicesPlaySystemSound(1104)
                }
                engine.onLand = {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    line = engine.winner.lines.randomElement() ?? ""
                }
                haptic.prepare()
            }
            .onChange(of: geo.size) { _, s in engine.size = s }
        }
        .preferredColorScheme(.dark)
    }

    private var blobs: some View {
        ZStack {
            ForEach(engine.blobs, id: \.index) { b in
                let side = max(140, engine.size.width * 0.5)
                ZStack {
                    Circle()
                        .fill(RadialGradient(stops: [
                            .init(color: b.kind.orbColor, location: 0),
                            .init(color: b.kind.orbColor.opacity(0.72), location: 0.26),
                            .init(color: b.kind.orbColor.opacity(0), location: 0.66),
                        ], center: .center, startRadius: 0, endRadius: side / 2))
                        .blur(radius: b.blur)
                }
                .frame(width: side, height: side)
                .scaleEffect(b.s)
                .opacity(b.o)
                .position(x: b.x, y: b.y)
                .allowsHitTesting(false)
            }
        }
    }

    private var isHome: Bool { engine.mode == .idle || engine.mode == .charging }

    private func home(in size: CGSize) -> some View {
        ZStack {
            FiveDotMark(mono: true)
                .frame(width: size.width * 0.15, height: size.width * 0.15)
                .position(x: size.width / 2, y: size.height * 0.42)
            Text(engine.mode == .charging && engine.charge > 0.12 ? "let go…" : "Shuffle")
                .font(.system(size: size.width * 0.046, weight: .medium))
                .foregroundStyle(Color(hex: 0x0B1316))
                .padding(.horizontal, size.width * 0.076)
                .padding(.vertical, size.width * 0.034)
                .background(Capsule().fill(Color(hex: 0xF6F7F4)))
                .shadow(color: .white.opacity(0.28), radius: engine.charge * 22)
                .scaleEffect(1 - engine.charge * 0.08)
                .position(x: size.width / 2, y: size.height * 0.735)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressing { pressing = true; engine.pressDown() } }
                    .onEnded { _ in pressing = false; engine.release() })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Shuffle")
                .accessibilityAction { engine.start() }
        }
        .opacity(isHome ? 1 : 0)
        .blur(radius: isHome ? 0 : 6)
        .offset(y: isHome ? 0 : 8)
        .animation(.easeOut(duration: 0.45), value: isHome)
        .allowsHitTesting(isHome)
    }

    private func shuffling(in size: CGSize) -> some View {
        let on = engine.mode == .shuffle
        return ZStack {
            HStack(spacing: 0) {
                Text("shuffling")
                Text("…")
            }
            .font(.displayItalic(size.width * 0.08))
            .foregroundStyle(Palette.ink)
            .position(x: size.width / 2, y: size.height * 0.445)
            Button { engine.skip() } label: {
                Text("Skip →").font(.system(size: size.width * 0.037)).foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .position(x: size.width / 2, y: size.height * 0.9)
        }
        .opacity(on ? 1 : 0)
        .blur(radius: on ? 0 : 6)
        .offset(y: on ? 0 : 10)
        .animation(.easeOut(duration: 0.5).delay(on ? 0.2 : 0), value: on)
        .allowsHitTesting(on)
    }

    private func result(in size: CGSize) -> some View {
        let on = engine.showResult
        return ZStack {
            Text(engine.winner.headline)
                .font(.displayItalic(size.width * 0.096))
                .foregroundStyle(Palette.ink)
                .position(x: size.width / 2, y: size.height * 0.243)
                .opacity(on ? 1 : 0).offset(y: on ? 0 : 12)
                .animation(.easeOut(duration: 0.6).delay(0.1), value: on)
            Image(systemName: engine.winner.lineIcon)
                .font(.system(size: size.width * 0.2, weight: .ultraLight))
                .foregroundStyle(.white)
                .position(x: size.width / 2, y: size.height * 0.41)
                .scaleEffect(on ? 1 : 0.4)
                .opacity(on ? 1 : 0)
                .animation(.spring(duration: 0.9, bounce: 0.35).delay(0.05), value: on)
            Text(line)
                .font(.system(size: size.width * 0.043))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(width: size.width * 0.8)
                .position(x: size.width / 2, y: size.height * 0.594)
                .opacity(on ? 1 : 0).offset(y: on ? 0 : 12)
                .animation(.easeOut(duration: 0.6).delay(0.35), value: on)
            HStack(spacing: size.width * 0.11) {
                if rerollsLeft > 0 {
                    Button {
                        rerollsLeft -= 1
                        engine.start()
                    } label: {
                        Label("1 free reroll", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: size.width * 0.048))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("Fate has spoken.")
                        .font(.displayItalic(size.width * 0.048))
                        .foregroundStyle(Palette.secondary)
                }
                Button("Let's go") { onStart(engine.winner) }
                    .font(.system(size: size.width * 0.048, weight: .medium))
                    .foregroundStyle(Color(hex: 0x0B1316))
                    .padding(.horizontal, size.width * 0.066)
                    .padding(.vertical, size.width * 0.034)
                    .background(Capsule().fill(Color(hex: 0xF6F7F4)))
            }
            .position(x: size.width / 2, y: size.height * 0.774)
            .opacity(on ? 1 : 0).offset(y: on ? 0 : 12)
            .animation(.easeOut(duration: 0.6).delay(0.5), value: on)
        }
        .allowsHitTesting(on)
    }
}

/// Finley's five-dot logo placeholder: one dot per media type, in a pentagon.
struct FiveDotMark: View {
    var mono = false
    /// One color for every dot (overrides `mono`).
    var dotColor: Color? = nil
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let spots: [(CGFloat, CGFloat, MomentKind)] = [(0.5, 0.17, .video), (0.83, 0.41, .photo), (0.7, 0.79, .word), (0.3, 0.79, .voice), (0.17, 0.41, .doodle)]
            ZStack {
                ForEach(spots.indices, id: \.self) { i in
                    Circle()
                        .fill(dotColor ?? (mono ? Color.white : spots[i].2.orbColor))
                        .frame(width: s * 0.27, height: s * 0.27)
                        .blur(radius: s * 0.012)
                        .position(x: spots[i].0 * s, y: spots[i].1 * s)
                }
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}


// MARK: Doodle

/// Finger-drawing canvas on paper. Exports a PNG of the drawing on paper.
struct DoodleCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    static let paper = UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1)

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(white: 0.1, alpha: 1), width: 6)
        canvas.backgroundColor = Self.paper
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: DoodleCanvas
        init(_ parent: DoodleCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }

    /// The drawing composited on paper, square.
    static func render(_ drawing: PKDrawing, side: CGFloat) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        // PencilKit adapts ink to the current appearance; render as light so black stays black.
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: 2)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            paper.setFill()
            ctx.fill(rect)
            ink.draw(in: rect)
        }
    }
}
