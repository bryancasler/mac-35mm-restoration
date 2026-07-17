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
