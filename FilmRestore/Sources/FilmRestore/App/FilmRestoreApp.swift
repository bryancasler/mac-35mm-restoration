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
        // Headless provisioning (verification/CI use; the GUI path adds the
        // per-download approval sheet — running this flag IS the approval).
        if CommandLine.arguments.contains("--provision") {
            let p = PluginProvisioner()
            p.onStatus = { print($0) }
            let sema = DispatchSemaphore(value: 0)
            // Task.detached: an inherited-context Task would land on the main
            // actor here (@main entry) and deadlock against sema.wait()
            Task.detached {
                do {
                    try await p.provisionPrebuilts()
                    try await p.buildDeScratch()
                } catch {
                    print("PROVISION FAILED: \(error.localizedDescription)")
                    exit(1)
                }
                sema.signal()
            }
            sema.wait()
            print("PROVISION OK")
            exit(0)
        }
        if CommandLine.arguments.contains("--doctor") {
            let s = DependencyDetector.detect()
            print("ffmpeg:      \(s.ffmpeg)")
            print("vapoursynth: \(s.vapoursynth)")
            print("bestsource:  \(s.bestsource)")
            print("meson/ninja: \(s.mesonNinja)")
            for (dylib, present) in s.plugins.sorted(by: { $0.key < $1.key }) {
                print("plugin \(present ? "OK " : "MISSING") \(dylib)")
            }
            print("plugin \(s.descratch ? "OK " : "MISSING") \(PluginSpec.descratchDylib)")
            let r = Doctor.run()
            print("doctor: \(r.ok ? "PASS" : "FAIL") — \(r.detail)")
            exit(r.ok && s.vsStackOK ? 0 : 1)
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
