import Foundation

/// Phase-2 invocation: `vspipe -c y4m job.vpy - | ffmpeg …` (ADR-2, proven S3).
/// Two Processes joined by a Pipe; ffmpeg's -progress is the primary signal,
/// vspipe stderr (`Frame: N/M`, CR-delimited) is secondary + logged.
struct ChainPlan {
    var vpyContent: String
    var ffmpegArgs: [String]     // starts at "-f yuv4mpegpipe -i -" (stdin)
    var outputURL: URL
    var totalFrames: Int
    var sourceURL: URL
}

final class VapourSynthBackend {
    static var scriptsDir: URL? {
        // Prefer the .app's own copy — Bundle.module's compiled-in fallback
        // points at the build tree, which won't exist for a distributed app.
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("FilmRestore_FilmRestore.bundle/scripts")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return Bundle.module.url(forResource: "scripts", withExtension: nil)
    }

    func run(plan: ChainPlan,
             estimatedOutputBytes: Int64,
             onProgress: @escaping (JobProgress) -> Void) async throws -> URL {
        let available = DiskGuard.availableBytes(for: plan.outputURL)
        guard DiskGuard.hasRoom(estimatedBytes: estimatedOutputBytes, destination: plan.outputURL) else {
            throw JobError.notEnoughDiskSpace(needed: estimatedOutputBytes, available: available)
        }

        let log = JobLog(jobName: "vs_chain")
        let sleep = SleepPreventer()
        sleep.begin(reason: "FilmRestore restoring")
        defer {
            sleep.end()
            log.close()
        }

        // job .vpy on disk
        let vpyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("filmrestore_job_\(UUID().uuidString).vpy")
        try plan.vpyContent.write(to: vpyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vpyURL) }
        log.line("vpy:\n\(plan.vpyContent)")
        log.line("ffmpeg \(plan.ffmpegArgs.joined(separator: " "))")

        // vspipe → pipe → ffmpeg
        let vspipe = Process()
        vspipe.executableURL = URL(fileURLWithPath: DependencyDetector.vspipe)
        vspipe.arguments = ["-c", "y4m", vpyURL.path, "-"]
        vspipe.environment = ProcessInfo.processInfo.environment.merging(
            ["VAPOURSYNTH_EXTRA_PLUGIN_PATH": DependencyDetector.pluginDir.path]) { _, n in n }

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: Tools.ffmpeg)
        ffmpeg.arguments = plan.ffmpegArgs

        let video = Pipe()
        vspipe.standardOutput = video
        ffmpeg.standardInput = video

        let vsErr = Pipe(), ffOut = Pipe(), ffErr = Pipe()
        vspipe.standardError = vsErr
        ffmpeg.standardOutput = ffOut
        ffmpeg.standardError = ffErr

        let parser = ProgressParser(totalFrames: plan.totalFrames)
        let q = DispatchQueue(label: "vs.chain.callbacks")
        let ffOutSplit = LineSplitter(), ffErrSplit = LineSplitter(), vsErrSplit = LineSplitter()

        ffOut.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            q.async {
                ffOutSplit.feed(data) { line in
                    if let snap = parser.feed(line: line) { onProgress(snap) }
                }
            }
        }
        ffErr.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            q.async { ffErrSplit.feed(data) { log.line("[ffmpeg] \($0)") } }
        }
        vsErr.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            q.async { vsErrSplit.feed(data) { log.line("[vspipe] \($0)") } }
        }

        try vspipe.run()
        try ffmpeg.run()
        // parent must not hold the video pipe open or ffmpeg never sees EOF
        try? video.fileHandleForReading.close()
        try? video.fileHandleForWriting.close()

        let statuses: (vs: Int32, ff: Int32) = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(Int32, Int32), Never>) in
                DispatchQueue.global().async {
                    vspipe.waitUntilExit()
                    ffmpeg.waitUntilExit()
                    q.async {
                        ffOut.fileHandleForReading.readabilityHandler = nil
                        ffErr.fileHandleForReading.readabilityHandler = nil
                        vsErr.fileHandleForReading.readabilityHandler = nil
                        cont.resume(returning: (vspipe.terminationStatus, ffmpeg.terminationStatus))
                    }
                }
            }
        } onCancel: {
            if vspipe.isRunning { vspipe.terminate() }
            if ffmpeg.isRunning { ffmpeg.terminate() }
        }

        log.line("vspipe exit \(statuses.vs), ffmpeg exit \(statuses.ff)")

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: plan.outputURL)
            throw JobError.cancelled
        }
        // S4 rule: process exit is completion; vspipe SIGPIPE(13→141) only counts
        // as failure when ffmpeg also failed
        guard statuses.ff == 0 else {
            try? FileManager.default.removeItem(at: plan.outputURL)
            throw JobError.ffmpegFailed(status: statuses.ff, stderrTail: "see job log \(log.url.lastPathComponent)")
        }
        guard statuses.vs == 0 else {
            try? FileManager.default.removeItem(at: plan.outputURL)
            throw JobError.ffmpegFailed(status: statuses.vs, stderrTail: "vspipe failed — see job log \(log.url.lastPathComponent)")
        }
        return plan.outputURL
    }

    // MARK: plan builders

    /// Full restore: VS chain video + audio muxed from source (S3 topology).
    static func fullRunPlan(media: MediaInfo, deflicker: DeflickerSettings,
                            scratch: ScratchSettings, dirt: DirtSettings,
                            encode: EncodeSettings, scriptsDir: URL,
                            passes: Int = 1) -> ChainPlan {
        let out = JobPlan.outputURL(for: media.url)
        let vpy = VpyTemplate.render(source: media.url, trimRange: nil,
                                     deflicker: deflicker, scratch: scratch,
                                     dirt: dirt, scriptsDir: scriptsDir, passes: passes)
        var args: [String] = ["-nostdin", "-hide_banner",
                              "-f", "yuv4mpegpipe", "-i", "-",
                              "-i", media.url.path,
                              "-map", "0:v:0", "-map", "1:a?"]
        args += encode.videoArgs
        args += JobPlan.colorArgs(media)
        args += encode.audioArgs
        args += ["-shortest", "-progress", "pipe:1", out.path]
        return ChainPlan(vpyContent: vpy, ffmpegArgs: args, outputURL: out,
                         totalFrames: media.totalFrames, sourceURL: media.url)
    }

    /// Test clip: trimmed in the .vpy (frame-exact), video-only MP4 (ADR-8).
    static func testClipPlan(media: MediaInfo, deflicker: DeflickerSettings,
                             scratch: ScratchSettings, dirt: DirtSettings,
                             encode: EncodeSettings, scriptsDir: URL,
                             start: Double, duration: Double, label: String,
                             passes: Int = 1) -> ChainPlan {
        let startFrame = Int((start * media.fps).rounded())
        let frames = Int((duration * media.fps).rounded())
        let endFrame = min(startFrame + frames, media.totalFrames)
        let out = AppDirs.testClips.appendingPathComponent("clip_\(label).mp4")
        try? FileManager.default.removeItem(at: out)
        let vpy = VpyTemplate.render(source: media.url,
                                     trimRange: startFrame..<endFrame,
                                     deflicker: deflicker, scratch: scratch,
                                     dirt: dirt, scriptsDir: scriptsDir, passes: passes)
        var args: [String] = ["-nostdin", "-hide_banner", "-y",
                              "-f", "yuv4mpegpipe", "-i", "-", "-an",
                              "-c:v", "hevc_videotoolbox", "-q:v", String(encode.quality),
                              "-tag:v", "hvc1"]
        args += JobPlan.colorArgs(media)
        args += ["-progress", "pipe:1", out.path]
        return ChainPlan(vpyContent: vpy, ffmpegArgs: args, outputURL: out,
                         totalFrames: endFrame - startFrame, sourceURL: media.url)
    }
}
