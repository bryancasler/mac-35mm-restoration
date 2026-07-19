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

    # MVTools no-op canary: v24 silently returned input frames unchanged from
    # Compensate on VS R77 (found 2026-07-18). Alternate dark/bright frames:
    # compensated frame 1 must resemble the PREVIOUS frame, not the current.
    dark = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=1, color=[40, 128, 128])
    bright = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=1, color=[210, 128, 128])
    pair = dark + bright
    sup = core.mv.Super(pair, pel=1)
    vec = core.mv.Analyse(sup, isb=False, delta=1, blksize=8, overlap=0)
    # thscd huge: disable the scene-change fallback (which legitimately
    # returns the current frame) so passthrough is unambiguous
    comp = core.mv.Compensate(pair, sup, vec, thscd1=16320, thscd2=255)
    f1 = core.std.PlaneStats(comp, plane=0).get_frame(1)
    avg = f1.props.PlaneStatsAverage * 255
    if abs(avg - 210) < 30:
        raise RuntimeError(
            f"mv.Compensate is a NO-OP (frame passthrough, avg={avg:.0f}) — "
            "broken MVTools/VapourSynth pairing; rebuild MVTools from source in Setup")
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
