import Foundation

/// M3 "doctor": proves the whole VS stack end-to-end by running a 10-frame
/// smoke .vpy through vspipe with the app-managed plugin path.
enum Doctor {
    static let smokeScript = """
    import vapoursynth as vs
    core = vs.core
    missing = [ns for ns in ("bs", "mv", "removedirt", "tmedian", "zsmooth", "descratch")
               if getattr(core, ns, None) is None]
    if missing:
        raise RuntimeError("missing plugins: " + ", ".join(missing))
    clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10)
    clip = core.descratch.DeScratch(clip, mindif=5, maxwidth=3)
    clip = core.zsmooth.TemporalMedian(clip, radius=1)
    clip.set_output()
    """

    struct Result {
        var ok: Bool
        var detail: String
    }

    static func run() -> Result {
        let dir = FileManager.default.temporaryDirectory
        let vpy = dir.appendingPathComponent("filmrestore_doctor.vpy")
        do {
            try smokeScript.write(to: vpy, atomically: true, encoding: .utf8)
        } catch {
            return Result(ok: false, detail: "could not write smoke script")
        }
        defer { try? FileManager.default.removeItem(at: vpy) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: DependencyDetector.vspipe)
        p.arguments = ["-p", vpy.path, "."]
        p.environment = ProcessInfo.processInfo.environment.merging(
            ["VAPOURSYNTH_EXTRA_PLUGIN_PATH": DependencyDetector.pluginDir.path]) { _, n in n }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return Result(ok: false, detail: "vspipe not runnable")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus == 0, output.contains("Output 10 frames") {
            return Result(ok: true, detail: "10-frame smoke render through all plugins OK")
        }
        return Result(ok: false, detail: String(output.suffix(400)))
    }
}
