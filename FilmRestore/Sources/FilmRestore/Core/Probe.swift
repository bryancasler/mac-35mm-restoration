import Foundation

/// ffprobe JSON decode + the S4 fallback chain: on MKV, stream-level nb_frames
/// and duration are N/A — total frames must come from format duration × fps.
struct MediaInfo: Equatable {
    var url: URL
    var width: Int
    var height: Int
    var fpsNum: Int
    var fpsDen: Int
    var durationSeconds: Double
    var sizeBytes: Int64
    var videoCodec: String
    var pixFmt: String
    var colorRange: String?     // e.g. "tv"
    var colorSpace: String?     // e.g. "bt709"
    var colorPrimaries: String?
    var colorTransfer: String?
    var audioTracks: [AudioTrack]

    struct AudioTrack: Equatable {
        var index: Int
        var codec: String
        var channels: Int
        var sampleRate: Int
    }

    var fps: Double { Double(fpsNum) / Double(fpsDen) }
    var totalFrames: Int { Int((durationSeconds * fps).rounded()) }
    var fpsDisplay: String { String(format: "%.3f", fps) }

    /// ~12x realtime measured for both backends (S2/S3).
    var estimatedFullRunSeconds: Double { durationSeconds / 12.0 }

    /// Pre-test-clip size estimate: 2.5 Mbps measured at q:v 60 (S3), scaled
    /// roughly linearly with the quality slider. Refined by test-clip ratio later.
    func estimatedOutputBytes(quality: Int) -> Int64 {
        let mbps = 2.5 * Double(quality) / 60.0
        return Int64(durationSeconds * mbps * 1_000_000 / 8)
    }
}

enum ProbeError: LocalizedError {
    case ffprobeFailed(String)
    case noVideoStream
    case badJSON

    var errorDescription: String? {
        switch self {
        case .ffprobeFailed(let msg): return "ffprobe failed: \(msg)"
        case .noVideoStream: return "No video stream found in file"
        case .badJSON: return "Could not parse ffprobe output"
        }
    }
}

enum Probe {
    // ffprobe JSON shapes (only what we read)
    private struct Root: Decodable {
        var streams: [Stream]
        var format: Format
    }
    private struct Stream: Decodable {
        var index: Int
        var codec_type: String
        var codec_name: String?
        var width: Int?
        var height: Int?
        var pix_fmt: String?
        var avg_frame_rate: String?
        var r_frame_rate: String?
        var color_range: String?
        var color_space: String?
        var color_primaries: String?
        var color_transfer: String?
        var channels: Int?
        var sample_rate: String?
        var nb_frames: String?
    }
    private struct Format: Decodable {
        var duration: String?
        var size: String?
    }

    static func probe(_ url: URL) throws -> MediaInfo {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.ffprobe)
        p.arguments = ["-v", "error", "-print_format", "json",
                       "-show_format", "-show_streams", url.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ProbeError.ffprobeFailed(String(data: errData, encoding: .utf8) ?? "unknown")
        }
        return try parse(data: data, url: url)
    }

    static func parse(data: Data, url: URL) throws -> MediaInfo {
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else {
            throw ProbeError.badJSON
        }
        guard let v = root.streams.first(where: { $0.codec_type == "video" }) else {
            throw ProbeError.noVideoStream
        }
        let (num, den) = parseRate(v.avg_frame_rate ?? v.r_frame_rate ?? "0/1")
        let duration = Double(root.format.duration ?? "") ?? 0
        let audio = root.streams.filter { $0.codec_type == "audio" }.map {
            MediaInfo.AudioTrack(index: $0.index,
                                 codec: $0.codec_name ?? "?",
                                 channels: $0.channels ?? 0,
                                 sampleRate: Int($0.sample_rate ?? "") ?? 0)
        }
        return MediaInfo(
            url: url,
            width: v.width ?? 0,
            height: v.height ?? 0,
            fpsNum: num,
            fpsDen: den,
            durationSeconds: duration,
            sizeBytes: Int64(root.format.size ?? "") ?? 0,
            videoCodec: v.codec_name ?? "?",
            pixFmt: v.pix_fmt ?? "?",
            colorRange: normalizeTag(v.color_range),
            colorSpace: normalizeTag(v.color_space),
            colorPrimaries: normalizeTag(v.color_primaries),
            colorTransfer: normalizeTag(v.color_transfer),
            audioTracks: audio
        )
    }

    /// "24000/1001" → (24000, 1001)
    static func parseRate(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), d != 0 else {
            return (Int(Double(s) ?? 0), 1)
        }
        return (n, d)
    }

    /// ffprobe reports "unknown" for absent tags — only restate tags that exist (ADR-4/S3).
    private static func normalizeTag(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s != "unknown", s != "unspecified" else { return nil }
        return s
    }
}
