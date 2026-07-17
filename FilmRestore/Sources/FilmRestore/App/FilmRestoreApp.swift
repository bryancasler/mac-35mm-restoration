import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // Headless verification path (M2 criteria) — no window, exits with status.
        if let idx = CommandLine.arguments.firstIndex(of: "--selftest"),
           CommandLine.arguments.count > idx + 1 {
            SelfTest.run(path: CommandLine.arguments[idx + 1])
            return
        }
        FilmRestoreApp.main()
    }
}

struct FilmRestoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("FilmRestore") {
            ContentView()
                .environmentObject(model)
                .onAppear { AppDirs.ensureAll() }
        }
    }
}

/// Running from a bare SwiftPM executable (no .app bundle until M5): claim
/// regular-app status so the window fronts and receives key events.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
