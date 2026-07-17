import Foundation

enum JobError: LocalizedError {
    case notEnoughDiskSpace(needed: Int64, available: Int64)
    case ffmpegFailed(status: Int32, stderrTail: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notEnoughDiskSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough disk space: need ~\(f.string(fromByteCount: needed)), "
                 + "only \(f.string(fromByteCount: available)) free"
        case .ffmpegFailed(let status, let tail):
            return "ffmpeg exited with status \(status)\n…\(tail)"
        case .cancelled:
            return "Job cancelled"
        }
    }
}

/// Phase-1 backend: runs a JobPlan through ffmpeg with progress, sleep
/// prevention, disk guard, and a per-job log (ADR-2/9/10).
final class FFmpegBackend {
    /// Runs the plan; `onProgress` is called from a background queue.
    func run(plan: JobPlan,
             estimatedOutputBytes: Int64,
             onProgress: @escaping (JobProgress) -> Void) async throws -> URL {
        let available = DiskGuard.availableBytes(for: plan.outputURL)
        guard DiskGuard.hasRoom(estimatedBytes: estimatedOutputBytes, destination: plan.outputURL) else {
            throw JobError.notEnoughDiskSpace(needed: estimatedOutputBytes, available: available)
        }

        let log = JobLog(jobName: logName(for: plan.kind))
        log.line("ffmpeg \(plan.args.joined(separator: " "))")
        let sleep = SleepPreventer()
        sleep.begin(reason: "FilmRestore encoding")
        defer {
            sleep.end()
            log.close()
        }

        let parser = ProgressParser(totalFrames: plan.totalFrames)
        let runner = ProcessRunner(tool: Tools.ffmpeg, arguments: plan.args)
        runner.onStdoutLine = { line in
            if let snapshot = parser.feed(line: line) { onProgress(snapshot) }
        }
        runner.onStderrLine = { line in log.line(line) }

        let status = try await runner.run()
        log.line("exit status \(status)")

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: plan.outputURL) // partial file
            throw JobError.cancelled
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: plan.outputURL)
            throw JobError.ffmpegFailed(status: status,
                                        stderrTail: String(runner.capturedStderr.suffix(800)))
        }
        return plan.outputURL
    }

    private func logName(for kind: JobPlan.Kind) -> String {
        switch kind {
        case .fullRun: return "fullrun"
        case .testClipSource: return "clipA"
        case .testClipFiltered: return "clipB"
        }
    }
}
