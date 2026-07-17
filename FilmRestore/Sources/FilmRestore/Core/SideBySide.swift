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

    /// Single-generation segment render, ffmpeg-only path: decode the source
    /// segment ONCE, split it, filter one branch, hstack, encode ONCE at the
    /// user's quality. No intermediate encodes (source left, restored right —
    /// no drawtext in brew ffmpeg).
    static func oneShotArgs(source: URL, start: Double, duration: Double,
                            filterChain: String, quality: Int, output: URL) -> [String] {
        let chain = filterChain.isEmpty ? "null" : filterChain
        return ["-nostdin", "-hide_banner", "-y",
                "-ss", String(format: "%.6f", start),
                "-t", String(format: "%.6f", duration),
                "-i", source.path, "-an",
                "-filter_complex", "[0:v]split[a][b];[b]\(chain)[f];[a][f]hstack=inputs=2:shortest=1",
                "-c:v", "hevc_videotoolbox", "-q:v", String(quality), "-tag:v", "hvc1",
                "-progress", "pipe:1", output.path]
    }

    /// Single-generation segment render, VS path: the .vpy already outputs the
    /// stacked pair (StackHorizontal — same decode, same frame indices, exact
    /// alignment), so ffmpeg only encodes the y4m stream. No second input, no
    /// timestamp sync: the MKV's millisecond-rounded PTS vs y4m's exact
    /// 24000/1001 clock made hstack's pairing wobble ±1 frame.
    static func vsEncodeArgs(quality: Int, output: URL) -> [String] {
        ["-nostdin", "-hide_banner", "-y",
         "-f", "yuv4mpegpipe", "-i", "-", "-an",
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
