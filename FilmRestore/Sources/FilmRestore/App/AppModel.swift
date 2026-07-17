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
            let planB = VapourSynthBackend.testClipPlan(
                media: media, deflicker: deflicker, scratch: scratch, dirt: dirt,
                encode: encode, scriptsDir: scripts,
                start: start, duration: clipDuration, label: "B_filtered")
            errorMessage = nil
            jobTask = Task {
                do {
                    self.jobLabel = "Rendering test clip A (source)…"
                    self.jobProgress = nil
                    _ = try await backend.run(plan: planA, estimatedOutputBytes: 50_000_000) { s in
                        Task { @MainActor in self.jobProgress = s }
                    }
                    self.jobLabel = "Rendering test clip B (restoration chain)…"
                    self.jobProgress = nil
                    _ = try await vsBackend.run(plan: planB, estimatedOutputBytes: 50_000_000) { s in
                        Task { @MainActor in self.jobProgress = s }
                    }
                    self.finishTestClip(a: planA.outputURL, b: planB.outputURL)
                } catch { self.surface(error) }
                self.jobLabel = nil
                self.jobProgress = nil
            }
        } else {
            let planB = JobPlan.testClip(media: media, deflicker: deflicker, encode: encode,
                                         start: start, duration: clipDuration, filtered: true)
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
                encode: encode, scriptsDir: scripts)
            errorMessage = nil
            jobTask = Task {
                do {
                    self.jobLabel = "Restoring full video (VapourSynth chain)…"
                    self.jobProgress = nil
                    let est = estimatedFullRunBytes()
                    _ = try await vsBackend.run(plan: plan, estimatedOutputBytes: est) { s in
                        Task { @MainActor in self.jobProgress = s }
                    }
                    self.lastOutput = plan.outputURL
                } catch { self.surface(error) }
                self.jobLabel = nil
                self.jobProgress = nil
            }
        } else {
            let plan = JobPlan.fullRun(media: media, deflicker: deflicker, encode: encode)
            runJobs([(plan, "Restoring full video…")]) { [weak self] in
                self?.lastOutput = plan.outputURL
            }
        }
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
                            dirt: self.dirt, encode: self.encode, scriptsDir: scripts)
                        out = try await self.vsBackend.run(
                            plan: plan,
                            estimatedOutputBytes: m.estimatedOutputBytes(quality: self.encode.quality)) { s in
                            Task { @MainActor in self.jobProgress = s }
                        }
                    } else {
                        let plan = JobPlan.fullRun(media: m, deflicker: self.deflicker, encode: self.encode)
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
        errorMessage = error.localizedDescription
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
            return Int64(d * 2.5e6 / 8 * 2)
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
