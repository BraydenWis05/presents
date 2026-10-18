import AppIntents
import SwiftUI
import WidgetKit

/// Opens Presents straight into the draw. Uses the same link as the home screen widget.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a moment"
    static let description = IntentDescription("Opens Presents straight to the draw.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(DeepLink.capture))
    }
}

/// A button people can put on the lock screen, in Control Center or on the Action Button.
/// It never asks anything on its own; someone has to choose to put it there.
struct PresentsCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PresentsCapture") {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                // Placeholder glyph. Finley picks the final one.
                Label("Add a moment", systemImage: "sparkle")
            }
        }
        .displayName("Add a moment")
        .description("Opens Presents straight to the draw.")
    }
}
