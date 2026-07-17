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
        if let idx = CommandLine.arguments.firstIndex(of: "--selftest-vs"),
           CommandLine.arguments.count > idx + 1 {
            SelfTest.runVS(path: CommandLine.arguments[idx + 1])
            return
        }
        // Headless provisioning (verification/CI use; the GUI path adds the
        // per-download approval sheet — running this flag IS the approval).
        // Headless side-by-side smoke: 2 segments × 3 s, hstack + concat, verify.
        if let idx = CommandLine.arguments.firstIndex(of: "--selftest-sbs"),
           CommandLine.arguments.count > idx + 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            guard let media = try? Probe.probe(url) else { print("FAIL probe"); exit(1) }
            let backend = FFmpegBackend()
            let sema = DispatchSemaphore(value: 0)
            var stacked: [URL] = []
            let segs = [SideBySide.Segment(start: 60, duration: 3),
                        SideBySide.Segment(start: 120, duration: 3)]
            for (i, seg) in segs.enumerated() {
                let a = JobPlan.testClip(media: media, deflicker: DeflickerSettings(),
                                         encode: EncodeSettings(), start: seg.start,
                                         duration: seg.duration, filtered: false,
                                         outputName: "sbs_st_\(i)_A.mp4")
                let b = JobPlan.testClip(media: media, deflicker: DeflickerSettings(),
                                         encode: EncodeSettings(), start: seg.start,
                                         duration: seg.duration, filtered: true,
                                         passes: 2, outputName: "sbs_st_\(i)_B.mp4")
                let stackURL = AppDirs.testClips.appendingPathComponent("sbs_st_\(i).mp4")
                let stack = JobPlan(kind: .utility("hstack"),
                                    args: SideBySide.hstackArgs(a: a.outputURL, b: b.outputURL,
                                                                quality: 60, output: stackURL),
                                    outputURL: stackURL,
                                    totalFrames: Int(3 * media.fps), sourceURL: url)
                Task.detached {
                    do {
                        _ = try await backend.run(plan: a, estimatedOutputBytes: 10_000_000) { _ in }
                        _ = try await backend.run(plan: b, estimatedOutputBytes: 10_000_000) { _ in }
                        _ = try await backend.run(plan: stack, estimatedOutputBytes: 20_000_000) { _ in }
                        stacked.append(stackURL)
                    } catch { print("FAIL segment \(i): \(error.localizedDescription)") }
                    sema.signal()
                }
                sema.wait()
            }
            guard stacked.count == 2 else { print("FAIL segments"); exit(1) }
            let list = AppDirs.testClips.appendingPathComponent("sbs_st_concat.txt")
            let out = AppDirs.testClips.appendingPathComponent("sbs_st_final.mp4")
            try? FileManager.default.removeItem(at: out)
            try? SideBySide.writeConcatList(segments: stacked, to: list)
            let concat = JobPlan(kind: .utility("concat"),
                                 args: SideBySide.concatArgs(listFile: list, output: out),
                                 outputURL: out, totalFrames: Int(6 * media.fps), sourceURL: url)
            Task.detached {
                do { _ = try await backend.run(plan: concat, estimatedOutputBytes: 40_000_000) { _ in } }
                catch { print("FAIL concat: \(error.localizedDescription)") }
                sema.signal()
            }
            sema.wait()
            guard let p = try? Probe.probe(out) else { print("FAIL probe output"); exit(1) }
            let widthOK = p.width == media.width * 2
            let framesOK = abs(p.totalFrames - Int(6 * media.fps)) <= 2
            print("sbs output: \(p.width)x\(p.height), \(p.totalFrames) frames, "
                + "\(String(format: "%.2f", p.durationSeconds)) s")
            print(widthOK && framesOK ? "== SBS PASS" : "== SBS FAIL")
            exit(widthOK && framesOK ? 0 : 1)
        }
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
            let scripts = VapourSynthBackend.scriptsDir
            print("scripts:     \(scripts?.path ?? "MISSING (Bundle.module)")")
            let r = Doctor.run()
            print("doctor: \(r.ok ? "PASS" : "FAIL") — \(r.detail)")
            exit(r.ok && s.vsStackOK && scripts != nil ? 0 : 1)
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
