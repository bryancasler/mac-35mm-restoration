import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var media: MediaInfo?
    @Published var isProbing = false
    @Published var deflicker = DeflickerSettings()
    @Published var encode = EncodeSettings()

    @Published var clipStartString = "10:00"   // default per requirements
    @Published var clipDuration = 60.0

    @Published var jobLabel: String?           // nil = idle
    @Published var jobProgress: JobProgress?
    @Published var errorMessage: String?

    @Published var abClipA: URL?
    @Published var abClipB: URL?
    @Published var showABPlayer = false
    @Published var lastOutput: URL?
    @Published var testClipBytesPerSecond: Double?  // ADR-10 size refinement

    private var jobTask: Task<Void, Never>?
    private let backend = FFmpegBackend()

    var isBusy: Bool { jobLabel != nil }

    var toolsOK: Bool { Tools.isInstalled(Tools.ffmpeg) && Tools.isInstalled(Tools.ffprobe) }

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
        let planB = JobPlan.testClip(media: media, deflicker: deflicker, encode: encode,
                                     start: start, duration: clipDuration, filtered: true)
        runJobs([(planA, "Rendering test clip A (source)…"),
                 (planB, "Rendering test clip B (filtered)…")]) { [weak self] in
            guard let self else { return }
            self.abClipA = planA.outputURL
            self.abClipB = planB.outputURL
            if let size = try? FileManager.default.attributesOfItem(atPath: planB.outputURL.path)[.size] as? Int64 {
                self.testClipBytesPerSecond = Double(size) / self.clipDuration
            }
            self.showABPlayer = true
        }
    }

    func runFullRestore() {
        guard let media, !isBusy else { return }
        let plan = JobPlan.fullRun(media: media, deflicker: deflicker, encode: encode)
        runJobs([(plan, "Restoring full video…")]) { [weak self] in
            self?.lastOutput = plan.outputURL
        }
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
