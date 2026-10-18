import SwiftUI

/// Voice Memos-style live waveform: bars scroll in from the right, up to a playhead.
struct LiveWaveform: View {
    var levels: [CGFloat]
    var recording: Bool

    var body: some View {
        GeometryReader { geo in
            let bar: CGFloat = 3, gap: CGFloat = 2.5
            let slots = Int((geo.size.width * 0.72) / (bar + gap))
            let shown = Array(levels.suffix(slots))
            ZStack(alignment: .leading) {
                // Dotted baseline for what hasn't been said yet.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(Palette.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

                HStack(alignment: .center, spacing: gap) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                        Capsule()
                            .fill(Palette.ink)
                            .frame(width: bar, height: max(3, level * geo.size.height))
                    }
                }
                .frame(width: geo.size.width * 0.72, height: geo.size.height, alignment: .trailing)

                // Playhead.
                Capsule()
                    .fill(MomentKind.voice.orbColor)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: geo.size.width * 0.72 + 2)
                    .opacity(recording || !levels.isEmpty ? 1 : 0.4)
            }
            .animation(.linear(duration: 0.06), value: levels.count)
        }
    }
}
