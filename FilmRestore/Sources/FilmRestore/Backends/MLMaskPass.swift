import Foundation

/// Phase-3 ML tier (ADR-14): runs the BOPBTL scratch-detection U-Net over a
/// frame range in a separate mlenv subprocess, producing an FFV1 gray mask
/// video that maskclean fuses via `ml_mask` (spatial inpaint — persistent
/// scratches defeat temporal fill by definition).
enum MLMaskPass {
    static var mlenvPython: URL {
        AppDirs.appSupport.appendingPathComponent("mlenv/bin/python3")
    }
    static var weights: URL {
        AppDirs.appSupport.appendingPathComponent("models/scratch_detector.pt")
    }
    static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: mlenvPython.path)
            && FileManager.default.fileExists(atPath: weights.path)
    }

    /// Renders the mask video; reports progress 0…1 via callback (parsed from
    /// the script's `MLMASK frame=N/M` stderr lines).
    static func run(source: URL, output: URL, startFrame: Int, numFrames: Int,
                    onProgress: @escaping (Double) -> Void) async throws {
        guard isReady else {
            throw JobError.ffmpegFailed(status: -1,
                stderrTail: "AI engine not installed — open Setup and install it first")
        }
        guard let script = VapourSynthBackend.scriptsDir?
            .appendingPathComponent("ml_mask_pass.py") else {
            throw JobError.ffmpegFailed(status: -1, stderrTail: "ml_mask_pass.py missing from bundle")
        }
        try? FileManager.default.removeItem(at: output)
        let log = JobLog(jobName: "ml_mask")
        defer { log.close() }

        let runner = ProcessRunner(
            tool: mlenvPython.path,
            arguments: [script.path,
                        "--input", source.path,
                        "--output", output.path,
                        "--weights", weights.path,
                        "--start-frame", String(startFrame),
                        "--num-frames", String(numFrames),
                        "--device", "mps"])
        runner.onStderrLine = { line in
            log.line(line)
            if line.hasPrefix("MLMASK frame="),
               let frac = line.dropFirst("MLMASK frame=".count)
                    .split(separator: "/").map({ Double($0) ?? 0 }).chunkFraction() {
                onProgress(frac)
            }
        }
        let status = try await runner.run()
        log.line("ml_mask_pass exit \(status)")
        guard status == 0 else {
            throw JobError.ffmpegFailed(status: status,
                stderrTail: "AI mask pass failed — see log \(log.url.lastPathComponent)")
        }
    }
}

private extension Array where Element == Double {
    func chunkFraction() -> Double? {
        guard count == 2, self[1] > 0 else { return nil }
        return self[0] / self[1]
    }
}
