import Foundation

/// User-facing filter/encode settings (M2: ffmpeg-only, phase-1 command).
struct DeflickerSettings: Equatable {
    var enabled = true
    var size = 10            // 2...129
    var mode: Mode = .pm

    enum Mode: String, CaseIterable, Identifiable {
        case pm, am, median
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pm: return "Power mean (default)"
            case .am: return "Arithmetic mean"
            case .median: return "Median"
            }
        }
    }

    var filterString: String { "deflicker=mode=\(mode.rawValue):size=\(size)" }
}

struct EncodeSettings: Equatable {
    var codec: VideoCodec = .hevcVideoToolbox
    var quality = 60         // hevc_videotoolbox -q:v (1...100)
    var x265CRF = 18         // advanced
    var audio: AudioMode = .flac

    enum VideoCodec: String, CaseIterable, Identifiable {
        case hevcVideoToolbox, x265, ffv1
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hevcVideoToolbox: return "HEVC (VideoToolbox)"
            case .x265: return "HEVC (x265, slow)"
            case .ffv1: return "FFV1 (lossless, huge)"
            }
        }
    }

    enum AudioMode: String, CaseIterable, Identifiable {
        case flac, copy
        var id: String { rawValue }
        var label: String { self == .flac ? "FLAC (compress PCM)" : "Passthrough (copy)" }
    }

    var videoArgs: [String] {
        switch codec {
        case .hevcVideoToolbox:
            return ["-c:v", "hevc_videotoolbox", "-q:v", String(quality), "-tag:v", "hvc1"]
        case .x265:
            return ["-c:v", "libx265", "-crf", String(x265CRF), "-preset", "medium", "-tag:v", "hvc1"]
        case .ffv1:
            return ["-c:v", "ffv1", "-level", "3"]
        }
    }

    var audioArgs: [String] { ["-c:a", audio == .flac ? "flac" : "copy"] }
}

/// A fully-resolved job: the exact ffmpeg invocation plus everything the UI
/// needs to run and report it. The UI never builds argv itself (ADR-2).
struct JobPlan {
    enum Kind: Equatable {
        case fullRun
        case testClipSource(start: Double, duration: Double)   // A side (no filters)
        case testClipFiltered(start: Double, duration: Double) // B side
    }

    var kind: Kind
    var args: [String]           // ffmpeg arguments (no binary path)
    var outputURL: URL
    var totalFrames: Int
    var sourceURL: URL

    /// Colorimetry restated explicitly on every encode (ADR-4; only tags that exist).
    static func colorArgs(_ media: MediaInfo) -> [String] {
        var a: [String] = []
        if let v = media.colorSpace { a += ["-colorspace", v] }
        if let v = media.colorPrimaries { a += ["-color_primaries", v] }
        if let v = media.colorTransfer { a += ["-color_trc", v] }
        if let v = media.colorRange { a += ["-color_range", v] }
        return a
    }

    /// NAME.restored.mkv next to the source, with a collision counter —
    /// never overwrite anything (ADR-10).
    static func outputURL(for source: URL, ext: String = "mkv") -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base).restored.\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base).restored-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    static func fullRun(media: MediaInfo, deflicker: DeflickerSettings,
                        encode: EncodeSettings) -> JobPlan {
        let out = outputURL(for: media.url, ext: encode.codec == .ffv1 ? "mkv" : "mkv")
        var args: [String] = ["-nostdin", "-hide_banner", "-i", media.url.path, "-map", "0"]
        if deflicker.enabled { args += ["-vf", deflicker.filterString] }
        args += encode.videoArgs
        args += colorArgs(media)
        args += encode.audioArgs
        args += ["-progress", "pipe:1", out.path]
        return JobPlan(kind: .fullRun, args: args, outputURL: out,
                       totalFrames: media.totalFrames, sourceURL: media.url)
    }

    /// Test clips are video-only MP4/hvc1 — AVPlayer can't open MKV (ADR-8
    /// amendment). Both sides re-encode with identical -ss/-t so frames align.
    static func testClip(media: MediaInfo, deflicker: DeflickerSettings,
                         encode: EncodeSettings, start: Double, duration: Double,
                         filtered: Bool) -> JobPlan {
        let frames = Int((duration * media.fps).rounded())
        let name = filtered ? "clip_B_filtered.mp4" : "clip_A_source.mp4"
        let out = AppDirs.testClips.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        // -ss before -i: fast keyframe seek, then accurate to requested time
        var args: [String] = ["-nostdin", "-hide_banner", "-y",
                              "-ss", String(format: "%.6f", start),
                              "-t", String(format: "%.6f", duration),
                              "-i", media.url.path, "-map", "0:v:0", "-an"]
        if filtered && deflicker.enabled { args += ["-vf", deflicker.filterString] }
        // Preview clips always use VideoToolbox regardless of the full-run codec:
        // they exist for A/B viewing, and AVPlayer needs hvc1-in-MP4.
        args += ["-c:v", "hevc_videotoolbox", "-q:v", String(encode.quality), "-tag:v", "hvc1"]
        args += colorArgs(media)
        args += ["-progress", "pipe:1", out.path]
        let kind: Kind = filtered ? .testClipFiltered(start: start, duration: duration)
                                  : .testClipSource(start: start, duration: duration)
        return JobPlan(kind: kind, args: args, outputURL: out,
                       totalFrames: frames, sourceURL: media.url)
    }
}
