import CryptoKit
import Foundation

/// `FilmRestore --selftest <file>` — headless run of the M2 verification
/// criteria (docs/PLAN.md → Verification → M2) that a script can drive:
///   1. probe card fields correct (printed for comparison with manual ffprobe)
///   2. 60 s A/B test clips render
///   3. full restore of the file with monotonic ETA
///   4. source untouched (SHA-256 before/after)
///   5. per-job log written
enum SelfTest {
    /// `--selftest-vs <file>` — M4 verification: VS chain test clip (all three
    /// filters), mark-mode variant, then a full single-encode run with audio
    /// sync + colorimetry checks. VS stack must be provisioned (M3).
    static func runVS(path: String) {
        let url = URL(fileURLWithPath: path)
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
            if !ok { failures.append(name) }
        }

        print("== FilmRestore VS selftest: \(path)")
        guard let media = try? Probe.probe(url) else { print("FAIL  probe"); exit(1) }
        guard let scripts = VapourSynthBackend.scriptsDir else {
            print("FAIL  bundled scripts missing"); exit(1)
        }
        var deflicker = DeflickerSettings()
        var scratch = ScratchSettings(); scratch.enabled = true
        var dirt = DirtSettings(); dirt.enabled = true
        let encode = EncodeSettings()
        let backend = VapourSynthBackend()
        let sema = DispatchSemaphore(value: 0)

        func runChain(_ plan: ChainPlan, _ name: String, expectFrames: Int) {
            var ok = false
            var lastFrame = 0
            Task.detached {
                do {
                    let out = try await backend.run(plan: plan, estimatedOutputBytes: 200_000_000) { p in
                        lastFrame = p.frame
                    }
                    let probe = try? Probe.probe(out)
                    ok = probe.map { abs($0.totalFrames - expectFrames) <= 1 } ?? false
                    if !ok { print("  frames: \(probe?.totalFrames ?? -1) vs \(expectFrames)") }
                } catch { print("  error: \(error.localizedDescription)") }
                sema.signal()
            }
            sema.wait()
            check(name, ok, "progress reached frame \(lastFrame)")
        }

        // 1. VS test clip, full chain
        let start = min(600.0, max(0, media.durationSeconds - 60))
        let clip = VapourSynthBackend.testClipPlan(
            media: media, deflicker: deflicker, scratch: scratch, dirt: dirt,
            encode: encode, scriptsDir: scripts, start: start, duration: 60, label: "vs_selftest")
        runChain(clip, "vsClip.fullChain", expectFrames: clip.totalFrames)

        // 2. mark-mode variant
        scratch.markOnly = true
        let markClip = VapourSynthBackend.testClipPlan(
            media: media, deflicker: deflicker, scratch: scratch, dirt: dirt,
            encode: encode, scriptsDir: scripts, start: start, duration: 60, label: "vs_mark")
        runChain(markClip, "vsClip.markMode", expectFrames: markClip.totalFrames)
        scratch.markOnly = false

        // 3. full single-encode run with audio
        deflicker.enabled = true
        let full = VapourSynthBackend.fullRunPlan(
            media: media, deflicker: deflicker, scratch: scratch, dirt: dirt,
            encode: encode, scriptsDir: scripts)
        var fullOK = false
        var outputURL: URL?
        Task.detached {
            do {
                outputURL = try await backend.run(
                    plan: full,
                    estimatedOutputBytes: media.estimatedOutputBytes(quality: encode.quality)) { _ in }
                fullOK = true
            } catch { print("  error: \(error.localizedDescription)") }
            sema.signal()
        }
        sema.wait()
        check("vsFull.completed", fullOK, full.outputURL.lastPathComponent)
        if let out = outputURL, let p = try? Probe.probe(out) {
            check("vsFull.frameCount", abs(p.totalFrames - media.totalFrames) <= 1,
                  "\(p.totalFrames) vs \(media.totalFrames)")
            check("vsFull.audioPresent", !p.audioTracks.isEmpty,
                  p.audioTracks.first.map { "\($0.codec)" } ?? "none")
            check("vsFull.audioSync", abs(p.durationSeconds - media.durationSeconds) < 0.5,
                  String(format: "Δ%.3fs", p.durationSeconds - media.durationSeconds))
            check("vsFull.colorRestated", p.colorSpace == media.colorSpace)
            try? FileManager.default.removeItem(at: out)
        }

        print(failures.isEmpty ? "== ALL PASS" : "== FAILURES: \(failures.joined(separator: ", "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
            if !ok { failures.append(name) }
        }

        print("== FilmRestore selftest: \(path)")
        let sourceHashBefore = sha256(url: url)

        // 1. probe
        guard let media = try? Probe.probe(url) else {
            print("FAIL  probe"); exit(1)
        }
        print("probe: \(media.width)x\(media.height) \(media.fpsNum)/\(media.fpsDen) "
            + "\(media.videoCodec)/\(media.pixFmt) dur=\(media.durationSeconds)s "
            + "frames=\(media.totalFrames) audio=\(media.audioTracks.count) "
            + "color=\(media.colorSpace ?? "-")/\(media.colorRange ?? "-")")
        check("probe.video", media.width > 0 && media.height > 0 && media.fps > 0)
        check("probe.totalFrames", media.totalFrames > 0, "\(media.totalFrames)")

        let deflicker = DeflickerSettings()
        let encode = EncodeSettings()
        let backend = FFmpegBackend()
        let sema = DispatchSemaphore(value: 0)

        // 2. test clips (start 10 s in, or clamped)
        let start = min(10.0, max(0, media.durationSeconds - 60))
        let dur = min(60.0, media.durationSeconds)
        for filtered in [false, true] {
            let plan = JobPlan.testClip(media: media, deflicker: deflicker, encode: encode,
                                        start: start, duration: dur, filtered: filtered)
            var ok = false
            Task {
                do {
                    let out = try await backend.run(plan: plan, estimatedOutputBytes: 50_000_000) { _ in }
                    ok = FileManager.default.fileExists(atPath: out.path)
                } catch { print("  error: \(error.localizedDescription)") }
                sema.signal()
            }
            sema.wait()
            check("testClip.\(filtered ? "B" : "A")", ok)
        }

        // 3. full restore with ETA monotonicity
        let plan = JobPlan.fullRun(media: media, deflicker: deflicker, encode: encode)
        var etas: [Double] = []
        var jobOK = false
        var outputURL: URL?
        Task {
            do {
                let out = try await backend.run(
                    plan: plan,
                    estimatedOutputBytes: media.estimatedOutputBytes(quality: encode.quality)
                ) { p in
                    if let eta = p.etaSeconds { etas.append(eta) }
                }
                outputURL = out
                jobOK = true
            } catch { print("  error: \(error.localizedDescription)") }
            sema.signal()
        }
        sema.wait()
        check("fullRun.completed", jobOK, outputURL?.lastPathComponent ?? "")
        let monotonic = zip(etas, etas.dropFirst()).allSatisfy { $1 <= $0 + 0.001 }
        check("fullRun.etaMonotonic", monotonic && !etas.isEmpty, "\(etas.count) samples")
        if let out = outputURL {
            let probeOut = try? Probe.probe(out)
            check("output.frameCount",
                  probeOut.map { abs($0.totalFrames - media.totalFrames) <= 1 } ?? false,
                  "\(probeOut?.totalFrames ?? -1) vs \(media.totalFrames)")
            check("output.colorRestated",
                  probeOut.map { $0.colorSpace == media.colorSpace } ?? false)
        }

        // 4. source untouched
        check("source.untouched", sha256(url: url) == sourceHashBefore)

        // 5. log written
        let logs = (try? FileManager.default.contentsOfDirectory(at: AppDirs.logs,
                    includingPropertiesForKeys: [.contentModificationDateKey]))?.filter {
            $0.lastPathComponent.contains("fullrun")
        }
        check("log.written", !(logs ?? []).isEmpty)

        // cleanup the selftest output (it's a verification artifact, not user data)
        if let out = outputURL { try? FileManager.default.removeItem(at: out) }

        print(failures.isEmpty ? "== ALL PASS" : "== FAILURES: \(failures.joined(separator: ", "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func sha256(url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
