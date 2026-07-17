import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var media: MediaInfo?
    @Published var isProbing = false
    @Published var deflicker = DeflickerSettings()
    @Published var scratch = ScratchSettings()
    @Published var dirt = DirtSettings()
    @Published var encode = EncodeSettings()

    @Published var clipStartString = "10:00"   // default per requirements
    @Published var clipDuration = 60.0

    @Published var passes = 1                  // 1–3: run the whole chain N times (single encode)
    @Published var sbsStartString = "10:00"    // side-by-side custom mode
    @Published var sbsLengthString = "60"
    @Published var sbsOutput: URL?
    @Published var lastStats: String?          // completion stats line

    @Published var jobLabel: String?           // nil = idle
    @Published var jobProgress: JobProgress?
    @Published var errorMessage: String?

    @Published var queue: [URL] = []          // M5 job queue (full runs, current settings)
    @Published var queueResults: [String] = []

    @Published var abClipA: URL?
    @Published var abClipB: URL?
    @Published var showABPlayer = false
    @Published var lastOutput: URL?
    @Published var testClipBytesPerSecond: Double?  // ADR-10 size refinement

    private var jobTask: Task<Void, Never>?
    private let backend = FFmpegBackend()
    private let vsBackend = VapourSynthBackend()

    var isBusy: Bool { jobLabel != nil }

    var toolsOK: Bool { Tools.isInstalled(Tools.ffmpeg) && Tools.isInstalled(Tools.ffprobe) }

    var needsVS: Bool { VpyTemplate.needsVapourSynth(scratch: scratch, dirt: dirt) }

    /// Gate VS jobs on the stack actually being present (M3 detection).
    private func vsReady() -> Bool {
        let s = DependencyDetector.detect()
        if !s.vsStackOK {
            errorMessage = "Scratch/dirt removal needs the VapourSynth stack — open Setup (stethoscope icon) to install it."
            return false
        }
        return true
    }

    // MARK: file loading

    func load(url: URL) {
        guard !isBusy else { return }
        isProbing = true
        media = nil
        abClipA = nil; abClipB = nil
        testClipBytesPerSecond = nil
        Task {
            do {
                let info = try await Task.detached { try Probe.probe(url) }.value
                self.media = info
                let defaultStart = min(600.0, max(0, info.durationSeconds - 60))
                self.clipStartString = Self.format(seconds: defaultStart)
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isProbing = false
        }
    }

    // MARK: jobs

    func renderTestClip() {
        guard let media, !isBusy else { return }
        guard let start = clampedClipStart(media: media) else {
            errorMessage = "Bad timestamp — use MM:SS or HH:MM:SS"
            return
        }
        let planA = JobPlan.testClip(media: media, deflicker: deflicker, encode: encode,
                                     start: start, duration: clipDuration, filtered: false)

        if needsVS {
            guard vsReady(), let scripts = VapourSynthBackend.scriptsDir else {
                if VapourSynthBackend.scriptsDir == nil { errorMessage = "bundled scripts missing" }
                return
            }
            // A must use the same frame-exact bestsource trim as B — an ffmpeg
            // -ss seek pairs by ms-rounded MKV timestamps and can land ±1 frame
            // off, which the A/B frame-step makes obvious
            let planAvs = VapourSynthBackend.testClipPlan(
                media: media, deflicker: DeflickerSettings(enabled: false),
                scratch: ScratchSettings(), dirt: DirtSettings(),
                encode: encode, scriptsDir: scripts,
                start: start, duration: clipDuration, label: "A_source")
            let planB = VapourSynthBackend.testClipPlan(
                media: media, deflicker: deflicker, scratch: scratch, dirt: dirt,
                encode: encode, scriptsDir: scripts,
                start: start, duration: clipDuration, label: "B_filtered",
                passes: passes)
            errorMessage = nil
            jobTask = Task {
                do {
                    self.jobLabel = "Rendering test clip A (source)…"
                    self.jobProgress = nil
                    _ = try await vsBackend.run(plan: planAvs, estimatedOutputBytes: 50_000_000) { s in
                        Task { @MainActor in self.jobProgress = s }
                    }
                    self.jobLabel = "Rendering test clip B (restoration chain)…"
                    self.jobProgress = nil
                    _ = try await vsBackend.run(plan: planB, estimatedOutputBytes: 50_000_000) { s in
                        Task { @MainActor in self.jobProgress = s }
                    }
                    self.finishTestClip(a: planAvs.outputURL, b: planB.outputURL)
                } catch { self.surface(error) }
                self.jobLabel = nil
                self.jobProgress = nil
            }
        } else {
            let planB = JobPlan.testClip(media: media, deflicker: deflicker, encode: encode,
                                         start: start, duration: clipDuration, filtered: true,
                                         passes: passes)
            runJobs([(planA, "Rendering test clip A (source)…"),
                     (planB, "Rendering test clip B (filtered)…")]) { [weak self] in
                self?.finishTestClip(a: planA.outputURL, b: planB.outputURL)
            }
        }
    }

    private func finishTestClip(a: URL, b: URL) {
        abClipA = a
        abClipB = b
        if let size = try? FileManager.default.attributesOfItem(atPath: b.path)[.size] as? Int64 {
            testClipBytesPerSecond = Double(size) / clipDuration
        }
        showABPlayer = true
    }

    /// "Any two variants" (M4): keep the current B as the A side, then re-render
    /// B with changed settings and compare variant-vs-variant.
    func pinBAsA() {
        guard let b = abClipB else { return }
        let pinned = AppDirs.testClips.appendingPathComponent("clip_A_pinned.mp4")
        try? FileManager.default.removeItem(at: pinned)
        do {
            try FileManager.default.copyItem(at: b, to: pinned)
            abClipA = pinned
        } catch { errorMessage = "could not pin clip: \(error.localizedDescription)" }
    }

    func runFullRestore() {
        guard let media, !isBusy else { return }
        if needsVS {
            guard vsReady(), let scripts = VapourSynthBackend.scriptsDir else { return }
            let plan = VapourSynthBackend.fullRunPlan(
                media: media, deflicker: deflicker, scratch: scratch, dirt: dirt,
                encode: encode, scriptsDir: scripts, passes: passes)
            errorMessage = nil
            let wallStart = Date()
            jobTask = Task {
                do {
                    self.jobLabel = "Restoring full video (VapourSynth chain, \(self.passes)×)…"
                    self.jobProgress = nil
                    let est = estimatedFullRunBytes()
                    _ = try await vsBackend.run(plan: plan, estimatedOutputBytes: est) { s in
                        Task { @MainActor in self.jobProgress = s }
                    }
                    self.lastOutput = plan.outputURL
                    self.recordStats(label: "Full restore", started: wallStart,
                                     frames: plan.totalFrames, output: plan.outputURL)
                } catch { self.surface(error) }
                self.jobLabel = nil
                self.jobProgress = nil
            }
        } else {
            let plan = JobPlan.fullRun(media: media, deflicker: deflicker, encode: encode,
                                       passes: passes)
            runJobs([(plan, "Restoring full video…")]) { [weak self] in
                self?.lastOutput = plan.outputURL
            }
        }
    }

    // MARK: side-by-side comparison

    /// Renders source|restored comparison video. quick=true: six random 10 s
    /// segments stitched into a 1-minute reel; else the user's start+length.
    func renderSideBySide(quick: Bool) {
        guard let media, !isBusy else { return }
        if needsVS && !vsReady() { return }
        let segments: [SideBySide.Segment]
        if quick {
            var rng = SystemRandomNumberGenerator()
            segments = SideBySide.quickSampleSegments(duration: media.durationSeconds,
                                                      using: &rng)
        } else {
            guard let start = Self.parse(timestamp: sbsStartString),
                  let len = Double(sbsLengthString), len > 0 else {
                errorMessage = "Bad side-by-side start/length"
                return
            }
            let clampedStart = min(max(0, start), max(0, media.durationSeconds - len))
            segments = [SideBySide.Segment(start: clampedStart,
                                           duration: min(len, media.durationSeconds))]
        }

        // Pre-flight disk check: stacked segments (double width) + the final
        // reel — no A/B intermediates exist anymore (single-generation renders).
        let perSecond = encode.estimatedBytesPerSecond(width: media.width, height: media.height)
        let totalSeconds = segments.reduce(0.0) { $0 + $1.duration }
        let needed = Int64(perSecond * totalSeconds * 2 * 2)
        if !DiskGuard.hasRoom(estimatedBytes: needed, destination: media.url) {
            let f = ByteCountFormatter()
            errorMessage = "Side-by-side at quality \(encode.quality) needs roughly "
                + f.string(fromByteCount: needed) + " of scratch space — free up disk "
                + "or lower the quality slider."
            return
        }

        errorMessage = nil
        let wallStart = Date()
        jobTask = Task {
            do {
                var stacked: [URL] = []
                var totalFrames = 0
                for (i, seg) in segments.enumerated() {
                    let tag = segments.count > 1 ? " \(i + 1)/\(segments.count)" : ""
                    let frames = Int((seg.duration * media.fps).rounded())
                    // frame-aligned start so the ffmpeg seek and the VS trim
                    // land on the identical frame
                    let startFrame = Int((seg.start * media.fps).rounded())
                    let alignedStart = Double(startFrame) * Double(media.fpsDen) / Double(media.fpsNum)
                    let segEstimate = Int64(perSecond * seg.duration * 2 * 1.5)
                    let stackedURL = AppDirs.testClips.appendingPathComponent("sbs_\(i)_stacked.mp4")
                    self.jobLabel = "Side-by-side\(tag) (\(self.passes)×)…"
                    self.jobProgress = nil
                    totalFrames += frames

                    if self.needsVS, let scripts = VapourSynthBackend.scriptsDir {
                        // the .vpy outputs the stacked pair itself (exact frame
                        // alignment by construction); ffmpeg encodes ONCE
                        let vpy = VpyTemplate.render(source: media.url,
                                                     trimRange: startFrame..<(startFrame + frames),
                                                     deflicker: self.deflicker, scratch: self.scratch,
                                                     dirt: self.dirt, scriptsDir: scripts,
                                                     passes: self.passes, sideBySide: true)
                        let plan = ChainPlan(vpyContent: vpy,
                                             ffmpegArgs: SideBySide.vsEncodeArgs(
                                                quality: self.encode.quality, output: stackedURL),
                                             outputURL: stackedURL, totalFrames: frames,
                                             sourceURL: media.url)
                        _ = try await self.vsBackend.run(plan: plan, estimatedOutputBytes: segEstimate) { s in
                            Task { @MainActor in self.jobProgress = s }
                        }
                    } else {
                        // one decode, split, filter one branch, hstack, ONE encode
                        let chain = self.deflicker.enabled
                            ? JobPlan.filterChain(self.deflicker, passes: self.passes) : ""
                        let plan = JobPlan(kind: .utility("sbs_oneshot"),
                                           args: SideBySide.oneShotArgs(
                                              source: media.url, start: alignedStart,
                                              duration: seg.duration, filterChain: chain,
                                              quality: self.encode.quality, output: stackedURL),
                                           outputURL: stackedURL, totalFrames: frames,
                                           sourceURL: media.url)
                        _ = try await self.backend.run(plan: plan, estimatedOutputBytes: segEstimate) { s in
                            Task { @MainActor in self.jobProgress = s }
                        }
                    }
                    stacked.append(stackedURL)
                }

                // stitch (or move the single segment) next to the source
                let out = JobPlan.outputURL(for: media.url, ext: "mp4", suffix: "sidebyside")
                if stacked.count == 1 {
                    try FileManager.default.moveItem(at: stacked[0], to: out)
                } else {
                    self.jobLabel = "Side-by-side: stitching \(stacked.count) segments…"
                    let list = AppDirs.testClips.appendingPathComponent("sbs_concat.txt")
                    try SideBySide.writeConcatList(segments: stacked, to: list)
                    let stackedBytes = stacked.reduce(Int64(0)) {
                        $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0)
                    }
                    let concatPlan = JobPlan(kind: .utility("concat"),
                                             args: SideBySide.concatArgs(listFile: list, output: out),
                                             outputURL: out, totalFrames: totalFrames,
                                             sourceURL: media.url)
                    _ = try await self.backend.run(plan: concatPlan, estimatedOutputBytes: stackedBytes) { s in
                        Task { @MainActor in self.jobProgress = s }
                    }
                    try? FileManager.default.removeItem(at: list)
                    for f in stacked { try? FileManager.default.removeItem(at: f) }
                }
                self.sbsOutput = out
                self.recordStats(label: "Side-by-side", started: wallStart,
                                 frames: totalFrames, output: out)
            } catch {
                self.surface(error)
                // best-effort cleanup of this run's intermediates on failure too
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: AppDirs.testClips, includingPropertiesForKeys: nil) {
                    for f in files where f.lastPathComponent.hasPrefix("sbs_")
                        || f.lastPathComponent.hasPrefix("clip_sbs_") {
                        try? FileManager.default.removeItem(at: f)
                    }
                }
            }
            self.jobLabel = nil
            self.jobProgress = nil
        }
    }

    // MARK: completion stats

    func recordStats(label: String, started: Date, frames: Int, output: URL?) {
        let wall = Date().timeIntervalSince(started)
        guard wall > 0 else { return }
        var parts = [label,
                     "\(frames) frames",
                     String(format: "%.1f s", wall),
                     String(format: "%.0f fps", Double(frames) / wall)]
        if let media {
            let rt = (Double(frames) / media.fps) / wall
            parts.append(String(format: "%.1f× realtime", rt))
        }
        if let output,
           let size = try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        lastStats = parts.joined(separator: " · ")
    }

    // MARK: presets + queue (M5)

    func apply(preset: Preset) {
        deflicker = preset.deflicker
        scratch = preset.scratch
        dirt = preset.dirt
    }

    func enqueue(urls: [URL]) {
        queue.append(contentsOf: urls.filter { u in !queue.contains(u) && u != media?.url })
    }

    /// Runs every queued file (plus nothing else) sequentially with the current
    /// settings; per-file success/failure lands in queueResults.
    func runQueue() {
        guard !isBusy, !queue.isEmpty else { return }
        errorMessage = nil
        queueResults = []
        let files = queue
        jobTask = Task {
            for (i, url) in files.enumerated() {
                self.jobLabel = "Queue \(i + 1)/\(files.count): \(url.lastPathComponent)"
                self.jobProgress = nil
                do {
                    guard let m = try? await Task.detached(operation: { try Probe.probe(url) }).value else {
                        self.queueResults.append("✗ \(url.lastPathComponent): probe failed")
                        continue
                    }
                    let out: URL
                    if self.needsVS, let scripts = VapourSynthBackend.scriptsDir {
                        let plan = VapourSynthBackend.fullRunPlan(
                            media: m, deflicker: self.deflicker, scratch: self.scratch,
                            dirt: self.dirt, encode: self.encode, scriptsDir: scripts,
                            passes: self.passes)
                        out = try await self.vsBackend.run(
                            plan: plan,
                            estimatedOutputBytes: m.estimatedOutputBytes(quality: self.encode.quality)) { s in
                            Task { @MainActor in self.jobProgress = s }
                        }
                    } else {
                        let plan = JobPlan.fullRun(media: m, deflicker: self.deflicker,
                                                   encode: self.encode, passes: self.passes)
                        out = try await self.backend.run(
                            plan: plan,
                            estimatedOutputBytes: m.estimatedOutputBytes(quality: self.encode.quality)) { s in
                            Task { @MainActor in self.jobProgress = s }
                        }
                    }
                    self.queueResults.append("✓ \(out.lastPathComponent)")
                    self.queue.removeAll { $0 == url }
                } catch {
                    if Task.isCancelled { break }
                    self.queueResults.append("✗ \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.jobLabel = nil
            self.jobProgress = nil
        }
    }

    private func surface(_ error: Error) {
        if error is CancellationError { return }
        if let e = error as? JobError, case .cancelled = e { return }
        lastFailedJob = jobLabel
        errorMessage = error.localizedDescription
    }

    // MARK: debug report

    var lastFailedJob: String?

    /// Copies the full troubleshooting report to the clipboard (error alert's
    /// "Copy debug info" button).
    func copyDebugReport() {
        let report = DebugReport.build(error: errorMessage ?? "(no error message)",
                                       failedJob: lastFailedJob,
                                       media: media,
                                       deflicker: deflicker, scratch: scratch,
                                       dirt: dirt, encode: encode, passes: passes)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func estimatedFullRunBytes() -> Int64 {
        guard let media else { return 0 }
        if let bps = testClipBytesPerSecond, encode.codec == .hevcVideoToolbox {
            return Int64(bps * media.durationSeconds)
        }
        return media.estimatedOutputBytes(quality: encode.quality)
    }

    func cancelJob() {
        jobTask?.cancel()
    }

    private func runJobs(_ jobs: [(JobPlan, String)], onSuccess: @escaping () -> Void) {
        errorMessage = nil
        let wallStart = Date()
        jobTask = Task {
            do {
                for (plan, label) in jobs {
                    self.jobLabel = label
                    self.jobProgress = nil
                    let est = estimatedBytes(for: plan)
                    _ = try await backend.run(plan: plan, estimatedOutputBytes: est) { snapshot in
                        Task { @MainActor in self.jobProgress = snapshot }
                    }
                }
                if let last = jobs.last?.0 {
                    self.recordStats(label: jobs.count > 1 ? "Job batch" : "Job",
                                     started: wallStart,
                                     frames: jobs.reduce(0) { $0 + $1.0.totalFrames },
                                     output: last.outputURL)
                }
                onSuccess()
            } catch is CancellationError {
                // user cancelled — no error surface
            } catch let e as JobError {
                if case .cancelled = e {} else { self.errorMessage = e.localizedDescription }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.jobLabel = nil
            self.jobProgress = nil
        }
    }

    private func estimatedBytes(for plan: JobPlan) -> Int64 {
        guard let media else { return 0 }
        switch plan.kind {
        case .fullRun:
            if let bps = testClipBytesPerSecond, encode.codec == .hevcVideoToolbox {
                return Int64(bps * media.durationSeconds)     // test-clip-calibrated
            }
            if encode.codec == .ffv1 {
                return Int64(media.durationSeconds * 16_000_000 / 8 * 8) // ~16 MB/s measured class
            }
            return media.estimatedOutputBytes(quality: encode.quality)
        case .testClipSource(_, let d), .testClipFiltered(_, let d):
            return Int64(d * encode.estimatedBytesPerSecond(width: media.width,
                                                            height: media.height) * 1.5)
        case .utility:
            return 200_000_000
        }
    }

    // MARK: timestamp helpers

    func clampedClipStart(media: MediaInfo) -> Double? {
        guard let t = Self.parse(timestamp: clipStartString) else { return nil }
        return min(max(0, t), max(0, media.durationSeconds - clipDuration))
    }

    nonisolated static func parse(timestamp: String) -> Double? {
        let parts = timestamp.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    nonisolated static func format(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
