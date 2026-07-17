import Foundation

/// Side-by-side comparison builder: source (left) | restored (right).
/// Two modes: a chosen start+length, or "quick sample" — six random 10 s
/// segments stitched into a one-minute comparison reel.
enum SideBySide {
    struct Segment: Equatable {
        var start: Double
        var duration: Double
    }

    /// Six 10 s segments, one random pick inside each sixth of the runtime
    /// (stratified: spread across the whole film, never overlapping). Skips the
    /// first/last 15 s where leaders and tail damage live.
    static func quickSampleSegments(duration: Double,
                                    count: Int = 6,
                                    segmentLength: Double = 10,
                                    using rng: inout some RandomNumberGenerator) -> [Segment] {
        let lead = min(15.0, duration * 0.02)
        let usable = duration - 2 * lead
        guard usable > Double(count) * segmentLength else {
            // short file: single segment from the start of the usable window
            return [Segment(start: lead, duration: min(segmentLength, max(1, duration - lead)))]
        }
        let bin = usable / Double(count)
        return (0..<count).map { i in
            let binStart = lead + Double(i) * bin
            let slack = bin - segmentLength
            let offset = Double.random(in: 0...max(0.001, slack), using: &rng)
            return Segment(start: binStart + offset, duration: segmentLength)
        }
    }

    /// ffmpeg args: A + B → hstacked comparison segment (no drawtext in brew
    /// ffmpeg — layout is by convention: source left, restored right).
    static func hstackArgs(a: URL, b: URL, quality: Int, output: URL) -> [String] {
        ["-nostdin", "-hide_banner", "-y",
         "-i", a.path, "-i", b.path,
         "-filter_complex", "[0:v][1:v]hstack=inputs=2",
         "-c:v", "hevc_videotoolbox", "-q:v", String(quality), "-tag:v", "hvc1",
         "-progress", "pipe:1", output.path]
    }

    /// ffmpeg concat-demuxer args for stitching finished segments (stream copy).
    static func concatArgs(listFile: URL, output: URL) -> [String] {
        ["-nostdin", "-hide_banner", "-y",
         "-f", "concat", "-safe", "0", "-i", listFile.path,
         "-c", "copy", "-progress", "pipe:1", output.path]
    }

    static func writeConcatList(segments: [URL], to listFile: URL) throws {
        let body = segments
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n") + "\n"
        try body.write(to: listFile, atomically: true, encoding: .utf8)
    }
}
