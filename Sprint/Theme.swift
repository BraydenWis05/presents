import SwiftUI
import UIKit
import AVKit
import CoreText

// Dark, grainy and quiet: deep teal-black, Instrument Serif for the big moments,
// moments shown blurred until the reveal.

enum Palette {
    /// Primary text on the dark background.
    static let ink = Color(red: 0.95, green: 0.95, blue: 0.93)
    static let secondary = Color.white.opacity(0.55)
    static let accent = Color(red: 0.42, green: 0.70, blue: 0.80)
    /// Subtle fill for cards, chips and fields.
    static let fill = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.12)
    static let pink = Color(red: 0.86, green: 0.42, blue: 0.48)
    static let peach = Color(red: 0.88, green: 0.66, blue: 0.48)
    static let lilac = Color(red: 0.60, green: 0.56, blue: 0.80)
    static let sky = Color(red: 0.55, green: 0.70, blue: 0.76)
    static let paper = Color(red: 0.10, green: 0.14, blue: 0.15)
    static let backgroundTop = Color(red: 0.05, green: 0.08, blue: 0.09)
    static let backgroundBottom = Color(red: 0.03, green: 0.05, blue: 0.06)
}

enum Fonts {
    static let serif = "InstrumentSerif-Regular"
    static let serifItalic = "InstrumentSerif-Italic"

    /// Registers any fonts dropped into Sprint/Fonts, so no Info.plist entry is needed.
    static func register() {
        for ext in ["ttf", "otf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static var hasSerif: Bool { UIFont(name: serif, size: 12) != nil }
}

extension Font {
    /// Big moments: titles, dates, reveal night. Instrument Serif when bundled.
    static func display(_ size: CGFloat) -> Font {
        Fonts.hasSerif ? .custom(Fonts.serif, size: size) : .system(size: size, design: .serif)
    }
    static func displayItalic(_ size: CGFloat) -> Font {
        Fonts.hasSerif ? .custom(Fonts.serifItalic, size: size) : .system(size: size, design: .serif).italic()
    }
    /// Body copy, captions, prompts.
    static func copy(_ size: CGFloat) -> Font { .system(size: size) }
    /// Small labels and buttons.
    static func tag(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium) }
}

/// Small secondary label.
struct TagLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.tag(13))
            .foregroundStyle(Palette.secondary)
    }
}

enum Grain {
    static let image: UIImage = {
        let side = 200
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            for _ in 0..<(side * side / 2) {
                let x = Int.random(in: 0..<side), y = Int.random(in: 0..<side)
                UIColor(white: Bool.random() ? 0 : 1, alpha: .random(in: 0.02...0.09)).setFill()
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }()
}

struct GrainOverlay: View {
    var body: some View {
        Image(uiImage: Grain.image)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}

/// Deep teal-black backdrop with film grain. `intense` adds a soft glow for reveal night.
struct AppBackground: View {
    var intense = false
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.backgroundTop, Palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(Palette.accent.opacity(intense ? 0.35 : 0.12))
                .frame(width: 420)
                .blur(radius: 110)
                .offset(x: drift ? 60 : 110, y: drift ? -160 : -220)
            if intense {
                Circle()
                    .fill(Palette.pink.opacity(0.25))
                    .frame(width: 360)
                    .blur(radius: 110)
                    .offset(x: drift ? -120 : -80, y: drift ? 220 : 160)
            }
            GrainOverlay().opacity(0.9)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// A soft glowing disc. Used for voice memos and chapter covers.
struct RollOrb: View {
    var fill: Double
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle().fill(Palette.sky.opacity(0.55 + 0.35 * fill))
            Circle().fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 110))
            GrainOverlay().clipShape(Circle()).opacity(0.8)
        }
        .clipShape(Circle())
        .scaleEffect(breathe ? 1.02 : 0.98)
        .shadow(color: Palette.accent.opacity(0.35), radius: 30)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Dark frosted card.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.fill))
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.stroke, lineWidth: 0.8))
    }
}

/// Small stat tile: label over a big serif number.
struct WidgetTile: View {
    var label: String
    var value: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.tag(12)).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.display(40)).foregroundStyle(Palette.ink)
                if !unit.isEmpty {
                    Text(unit).font(.tag(13)).foregroundStyle(Palette.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.stroke, lineWidth: 0.8))
    }
}

/// Circle avatar with a muted gradient and a serif initial.
struct Avatar: View {
    var name: String
    var size: CGFloat = 44
    @Environment(RollStore.self) private var store

    private var color: Color {
        let palette: [UInt32] = [0xBCD3DC, 0xE2642E, 0xD257B4, 0x1A86A6, 0xE5D24A]
        return Color(hex: palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count])
    }

    var body: some View {
        if let data = store.state.avatars?[name], let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Palette.backgroundTop, lineWidth: 2))
        } else {
            initial
        }
    }

    private var initial: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.displayItalic(size * 0.5))
            .foregroundStyle(Color(hex: 0x0B1316).opacity(0.85))
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(Palette.backgroundTop, lineWidth: 2))
    }
}

/// Floating glass capsule with an icon and two lines.
struct GlassBubble<Leading: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Palette.fill)))
        .overlay(Capsule().stroke(Palette.stroke, lineWidth: 0.6))
    }
}

/// Faint twinkling glyphs. Purely decorative.
struct Sparkles: View {
    var glyphs = ["✦", "·", "✧", "·"]
    var count = 9
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            ForEach(0..<count, id: \.self) { i in
                let seed = Double(i) * 0.618
                Text(glyphs[i % glyphs.count])
                    .font(.system(size: 10 + CGFloat(i % 3) * 5))
                    .foregroundStyle(.white.opacity(0.7))
                    .position(
                        x: geo.size.width * (0.08 + seed.truncatingRemainder(dividingBy: 1) * 0.84),
                        y: geo.size.height * (0.1 + Double((i * 37) % 80) / 100)
                    )
                    .opacity(animate ? 0.9 : 0.15)
                    .animation(.easeInOut(duration: 1.8 + Double(i % 4) * 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.2), value: animate)
            }
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }
}

/// Floating capsule button. `.pill` is light on dark, `.frostedPill` is glass.
struct PillStyle: ButtonStyle {
    var primary = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .foregroundStyle(primary ? Palette.backgroundTop : Palette.ink)
            .background {
                if primary {
                    Capsule().fill(Palette.ink)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Palette.fill))
                        .overlay(Capsule().stroke(Palette.stroke, lineWidth: 0.6))
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

extension ButtonStyle where Self == PillStyle {
    static var pill: PillStyle { PillStyle() }
    static var frostedPill: PillStyle { PillStyle(primary: false) }
}

/// AirPlay picker so the reveal can go to a TV or projector.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(Palette.ink)
        view.activeTintColor = UIColor(Palette.accent)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

extension Date {
    var short: String { formatted(.dateTime.month(.abbreviated).day()) }
}

extension View {
    /// Adds a Done button above the keyboard, since multi-line fields swallow Return.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}
