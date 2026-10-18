import WidgetKit
import SwiftUI

/// Little lines that set a mood instead of giving an order. Never "take a photo".
enum Moods {
    static let lines = [
        "Who's making you laugh right now?",
        "Look up. What's the light doing?",
        "What does it sound like in here?",
        "Someone just said something good.",
        "This is the part you'll forget.",
        "Who's next to you?",
        "Nothing's happening. Perfect.",
        "What would you miss about right now?",
        "The getting-ready part counts too.",
        "Somebody's mid-story.",
        "Where did everyone end up?",
        "It's a normal Tuesday-ish moment.",
    ]

    /// Changes every few hours, the same on every phone at the same time.
    static func line(for date: Date) -> String {
        let slot = Int(date.timeIntervalSince1970 / (3 * 3600))
        return lines[slot % lines.count]
    }
}

struct RollEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let stack: UIImage?
    var mood: String { Moods.line(for: date) }

    static let preview = RollEntry(
        date: .now,
        snapshot: WidgetSnapshot(rollName: "Last semester", revealDate: .now.addingTimeInterval(60 * 86_400), momentCount: 12, isReadyToOpen: false, togetherWith: ["Isabelle", "Maya"]),
        stack: nil
    )
}

struct RollProvider: TimelineProvider {
    func placeholder(in context: Context) -> RollEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (RollEntry) -> Void) {
        completion(context.isPreview ? .preview : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RollEntry>) -> Void) {
        // A new mood line every 3 hours for the next day; the app also reloads on changes.
        let slot = 3.0 * 3600
        let start = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 / slot) * slot)
        let entries = (0..<8).map { current(at: start.addingTimeInterval(Double($0) * slot)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func current(at date: Date = .now) -> RollEntry {
        let stack = WidgetSnapshot.stackImageURL.flatMap { UIImage(contentsOfFile: $0.path()) }
        return RollEntry(date: date, snapshot: WidgetSnapshot.load(), stack: stack)
    }
}

private enum Look {
    static let background = Color(red: 0.05, green: 0.08, blue: 0.09)
    static let ink = Color(red: 0.95, green: 0.95, blue: 0.93)
    static let secondary = Color.white.opacity(0.6)

    static func serif(_ size: CGFloat) -> Font {
        UIFont(name: "InstrumentSerif-Regular", size: size) != nil
            ? .custom("InstrumentSerif-Regular", size: size)
            : .system(size: size, design: .serif)
    }
}

/// A quiet mood line on your home screen. Tap anywhere and you're straight into the draw.
struct PresentsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: RollEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium: medium(snapshot)
                default: small(snapshot)
                }
            } else {
                empty
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Look.background
                if family != .systemMedium, let stack = entry.stack {
                    Image(uiImage: stack).resizable().scaledToFill().opacity(0.55)
                    LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .widgetURL(entry.snapshot == nil ? DeepLink.open : DeepLink.capture)
    }

    // MARK: Small: the add button over the blurred roll.

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text(entry.mood)
                .font(Look.serif(22))
                .foregroundStyle(Look.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
                .padding(.bottom, 4)
            Text(snapshot.isReadyToOpen ? "Ready to open" : snapshot.revealDate.formatted(.dateTime.month(.abbreviated).day()))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Look.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Medium: the roll on the left, the call to add on the right.

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if let stack = entry.stack {
                    Image(uiImage: stack)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)).frame(width: 130, height: 130)
                }
                Text("\(snapshot.momentCount)")
                    .font(Look.serif(40))
                    .foregroundStyle(Look.ink)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.rollName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Look.secondary)
                    .lineLimit(1)
                Text(entry.mood)
                    .font(Look.serif(24))
                    .foregroundStyle(Look.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text(snapshot.isReadyToOpen ? "Ready to open together" : snapshot.revealDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 11))
                    .foregroundStyle(Look.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer()
            Text("Presents").font(.system(size: 11, weight: .semibold)).foregroundStyle(Look.secondary)
            Text("Start a chapter together").font(Look.serif(20)).foregroundStyle(Look.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PresentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PresentsRoll", provider: RollProvider()) { entry in
            PresentsWidgetView(entry: entry)
        }
        .configurationDisplayName("Presents")
        .description("A little line to notice the moment by.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PresentsWidgetBundle: WidgetBundle {
    var body: some Widget {
        PresentsWidget()
        PresentsCaptureControl()
    }
}

#Preview(as: .systemMedium) {
    PresentsWidget()
} timeline: {
    RollEntry.preview
}
