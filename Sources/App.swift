import SwiftUI
import AppKit

/// Light, dark, or following the system (the default). Everything uses adaptive colours, so it switches live.
enum Appearance {
    static let key = "appearance"
    static func apply(_ value: String? = UserDefaults.standard.string(forKey: key)) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AlbumExtractorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        signal(SIGPIPE, SIG_IGN)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #if UITEST
        if let a = ProcessInfo.processInfo.environment["IPHONE_UI_APPEARANCE"] { Appearance.apply(a); return }
        #endif
        Appearance.apply()
    }

    var body: some Scene {
        WindowGroup("PortHop") {
            RootView()
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) { TransitionToggle() }
        }
    }
}

struct TransitionToggle: View {
    @AppStorage("modernTransitions") private var modern = true
    var body: some View { Toggle("Animated Screen Transitions", isOn: $modern) }
}
