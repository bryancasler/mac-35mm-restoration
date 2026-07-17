import Foundation

/// Builds the paste-ready troubleshooting report behind the error alert's
/// "Copy debug info" button: the error, every setting, media facts, tool
/// versions, plugin state, and the tail of the newest job log.
enum DebugReport {
    static func build(error: String,
                      failedJob: String?,
                      media: MediaInfo?,
                      deflicker: DeflickerSettings,
                      scratch: ScratchSettings,
                      dirt: DirtSettings,
                      encode: EncodeSettings,
                      passes: Int) -> String {
        var s = "## FilmRestore debug report\n\n"
        s += "**Error:** \(error)\n"
        if let failedJob { s += "**During:** \(failedJob)\n" }
        s += "**When:** \(ISO8601DateFormatter().string(from: Date()))\n\n"

        if let m = media {
            s += "**Source:** \(m.url.path)\n"
            s += "- \(m.width)x\(m.height) · \(m.fpsDisplay) fps (\(m.fpsNum)/\(m.fpsDen)) · "
               + "\(m.videoCodec)/\(m.pixFmt) · \(m.totalFrames) frames · "
               + String(format: "%.1f s", m.durationSeconds) + "\n"
            s += "- color: space=\(m.colorSpace ?? "-") range=\(m.colorRange ?? "-") "
               + "primaries=\(m.colorPrimaries ?? "-") trc=\(m.colorTransfer ?? "-")\n"
            s += "- audio: " + (m.audioTracks.isEmpty ? "none"
                 : m.audioTracks.map { "\($0.codec) \($0.channels)ch \($0.sampleRate)Hz" }
                     .joined(separator: ", ")) + "\n\n"
        } else {
            s += "**Source:** none loaded\n\n"
        }

        s += "**Settings:**\n"
        s += "- passes: \(passes)\n"
        s += "- deflicker: enabled=\(deflicker.enabled) mode=\(deflicker.mode.rawValue) size=\(deflicker.size)\n"
        s += "- scratch: enabled=\(scratch.enabled) mindif=\(scratch.mindif) asym=\(scratch.asym) "
           + "maxgap=\(scratch.maxgap) maxwidth=\(scratch.oddMaxwidth) minlen=\(scratch.minlen) "
           + "maxangle=\(scratch.maxangle) markOnly=\(scratch.markOnly)\n"
        s += "- dirt: enabled=\(dirt.enabled) engine=\(dirt.engine.rawValue) "
           + "gmthreshold=\(dirt.gmthreshold) mthreshold=\(dirt.mthreshold) "
           + "thsad=\(dirt.thsad) radT=\(dirt.radT)\n"
        s += "- encode: codec=\(encode.codec.rawValue) quality=\(encode.quality) "
           + "x265CRF=\(encode.x265CRF) audio=\(encode.audio.rawValue)\n\n"

        s += "**Environment:**\n"
        s += "- ffmpeg: \(Tools.versionLine(of: Tools.ffmpeg) ?? "NOT FOUND")\n"
        let dep = DependencyDetector.detect()
        s += "- vapoursynth: \(describe(dep.vapoursynth))\n"
        s += "- bestsource: \(describe(dep.bestsource))\n"
        let plugins = dep.plugins.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value ? "ok" : "MISSING")" }
            .joined(separator: " ")
        s += "- plugins: \(plugins) descratch=\(dep.descratch ? "ok" : "MISSING")\n"
        s += "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
           + (ProcessInfo.processInfo.isLowPowerModeEnabled ? " · LOW POWER MODE ON" : "") + "\n\n"

        if let (name, tail) = latestLogTail() {
            s += "**Job log tail (\(name)):**\n```\n\(tail)\n```\n"
        }
        return s
    }

    private static func describe(_ state: DependencyStatus.State) -> String {
        switch state {
        case .ok(let d): return d
        case .missing(let r): return "MISSING (\(r))"
        }
    }

    /// Last 40 lines of the most recently modified job log.
    static func latestLogTail(maxLines: Int = 40) -> (name: String, tail: String)? {
        let fm = FileManager.default
        guard let logs = try? fm.contentsOfDirectory(
            at: AppDirs.logs, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let newest = logs
            .filter { $0.pathExtension == "log" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }
        guard let newest, let content = try? String(contentsOf: newest, encoding: .utf8) else {
            return nil
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return (newest.lastPathComponent, lines.suffix(maxLines).joined(separator: "\n"))
    }
}
