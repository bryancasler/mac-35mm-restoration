import Foundation

/// Parses ffmpeg `-progress pipe:1` key=value blocks into job progress.
/// Encodes every S4 rule:
///  - blocks arrive ~every 0.5 s; a block ends at the `progress=` line
///  - first block has fps=0.0 → no ETA until fps > 0
///  - `progress=end` carries frame=total reliably; process exit is completion
///  - displayed ETA is clamped monotonic (never jumps up) after warmup
struct JobProgress: Equatable {
    var frame = 0
    var fps = 0.0
    var speed = 0.0          // "12.3x" → 12.3
    var outTimeSeconds = 0.0
    var totalFrames: Int
    var etaSeconds: Double?  // nil during warmup
    var isEnded = false

    var fraction: Double {
        totalFrames > 0 ? min(1.0, Double(frame) / Double(totalFrames)) : 0
    }
}

final class ProgressParser {
    private(set) var progress: JobProgress
    private var pending: [String: String] = [:]
    private var bestETA = Double.infinity

    init(totalFrames: Int) {
        progress = JobProgress(totalFrames: totalFrames)
    }

    /// Feed one line of `-progress` output. Returns an updated snapshot when a
    /// block completes, else nil.
    @discardableResult
    func feed(line: String) -> JobProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[..<eq])
        let value = String(trimmed[trimmed.index(after: eq)...])
        guard key == "progress" else {
            pending[key] = value
            return nil
        }
        // block complete
        if let f = pending["frame"], let n = Int(f) { progress.frame = n }
        if let f = pending["fps"], let n = Double(f) { progress.fps = n }
        if let s = pending["speed"]?.dropLast(), let n = Double(s) { progress.speed = n }
        if let t = pending["out_time_us"], let n = Double(t) { progress.outTimeSeconds = n / 1_000_000 }
        pending.removeAll()

        if value == "end" {
            progress.isEnded = true
            progress.frame = max(progress.frame, progress.totalFrames)
            progress.etaSeconds = 0
        } else if progress.fps > 0 {
            let raw = Double(max(0, progress.totalFrames - progress.frame)) / progress.fps
            bestETA = min(bestETA, raw)
            progress.etaSeconds = bestETA
        }
        return progress
    }
}

/// Splits a raw byte stream into lines on \r OR \n, whichever comes first —
/// ffmpeg/vspipe interleave CR-delimited status with LF-delimited lines (S4).
final class LineSplitter {
    private var buffer = Data()
    private let separators: Set<UInt8> = [0x0A, 0x0D]

    func feed(_ data: Data, onLine: (String) -> Void) {
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { separators.contains($0) }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                onLine(line)
            }
        }
    }

    func flush(onLine: (String) -> Void) {
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            onLine(line)
        }
        buffer.removeAll()
    }
}
