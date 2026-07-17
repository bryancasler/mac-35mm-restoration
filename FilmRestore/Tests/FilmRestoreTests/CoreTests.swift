import XCTest
@testable import FilmRestore

final class ProgressParserTests: XCTestCase {
    func testBlockParsingAndETA() {
        let p = ProgressParser(totalFrames: 1440)
        // first block: fps=0 → no ETA (S4 rule 2)
        for line in ["frame=62", "fps=0.0", "speed=1.2x", "out_time_us=2583000", "progress=continue"] {
            _ = p.feed(line: line)
        }
        XCTAssertNil(p.progress.etaSeconds)
        XCTAssertEqual(p.progress.frame, 62)

        for line in ["frame=313", "fps=206.8", "speed=8.6x", "out_time_us=13000000", "progress=continue"] {
            _ = p.feed(line: line)
        }
        XCTAssertEqual(p.progress.etaSeconds!, Double(1440 - 313) / 206.8, accuracy: 0.01)
        XCTAssertEqual(p.progress.speed, 8.6, accuracy: 0.001)
    }

    func testETAMonotonicClamp() {
        let p = ProgressParser(totalFrames: 1000)
        _ = ["frame=500", "fps=100", "progress=continue"].map { p.feed(line: $0) }
        let first = p.progress.etaSeconds!
        // fps drops → raw ETA would jump up; display must not
        _ = ["frame=510", "fps=50", "progress=continue"].map { p.feed(line: $0) }
        XCTAssertLessThanOrEqual(p.progress.etaSeconds!, first)
    }

    func testEndBlock() {
        let p = ProgressParser(totalFrames: 100)
        _ = ["frame=100", "fps=50", "progress=end"].map { p.feed(line: $0) }
        XCTAssertTrue(p.progress.isEnded)
        XCTAssertEqual(p.progress.etaSeconds, 0)
        XCTAssertEqual(p.progress.fraction, 1.0)
    }

    func testLineSplitterMixedCRLF() {
        // S4 rule 4: CR-delimited Frame: lines interleaved with LF lines
        let splitter = LineSplitter()
        var lines: [String] = []
        splitter.feed("Frame: 1/10\rFrame: 2/10\rScript evaluation done\nFrame: 3/10\r".data(using: .utf8)!) {
            lines.append($0)
        }
        XCTAssertEqual(lines, ["Frame: 1/10", "Frame: 2/10", "Script evaluation done", "Frame: 3/10"])
    }

    func testLineSplitterChunkBoundary() {
        let splitter = LineSplitter()
        var lines: [String] = []
        splitter.feed("frame=1".data(using: .utf8)!) { lines.append($0) }
        XCTAssertTrue(lines.isEmpty)
        splitter.feed("23\nfps=8".data(using: .utf8)!) { lines.append($0) }
        XCTAssertEqual(lines, ["frame=123"])
        splitter.flush { lines.append($0) }
        XCTAssertEqual(lines, ["frame=123", "fps=8"])
    }
}

final class JobPlanTests: XCTestCase {
    private var media: MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/tmp/scan.mkv"), width: 1440, height: 1080,
                  fpsNum: 24000, fpsDen: 1001, durationSeconds: 5491.528,
                  sizeBytes: 25_239_465_137, videoCodec: "h264", pixFmt: "yuv420p",
                  colorRange: "tv", colorSpace: "bt709", colorPrimaries: nil,
                  colorTransfer: nil,
                  audioTracks: [.init(index: 1, codec: "pcm_s16be", channels: 2, sampleRate: 48000)])
    }

    func testTotalFramesFallbackChain() {
        // S4 rule 1: MKV totals come from format duration × fps
        XCTAssertEqual(media.totalFrames, 131_665)
    }

    func testFullRunMatchesValidatedCommand() {
        let plan = JobPlan.fullRun(media: media, deflicker: DeflickerSettings(),
                                   encode: EncodeSettings())
        let joined = plan.args.joined(separator: " ")
        // phase-1 validated command core (docs/PLAN.md)
        XCTAssertTrue(joined.contains("-map 0"))
        XCTAssertTrue(joined.contains("-vf deflicker=mode=pm:size=10"))
        XCTAssertTrue(joined.contains("-c:v hevc_videotoolbox -q:v 60 -tag:v hvc1"))
        XCTAssertTrue(joined.contains("-c:a flac"))
        XCTAssertTrue(joined.contains("-colorspace bt709"))
        XCTAssertTrue(joined.contains("-color_range tv"))
        XCTAssertFalse(joined.contains("-color_primaries"), "absent tags must not be restated")
        XCTAssertTrue(joined.contains("-progress pipe:1"))
        XCTAssertTrue(plan.outputURL.lastPathComponent == "scan.restored.mkv")
        XCTAssertEqual(plan.totalFrames, 131_665)
    }

    func testDeflickerDisabledOmitsFilter() {
        var d = DeflickerSettings(); d.enabled = false
        let plan = JobPlan.fullRun(media: media, deflicker: d, encode: EncodeSettings())
        XCTAssertFalse(plan.args.contains("-vf"))
    }

    func testTestClipIsVideoOnlyMP4(){
        let plan = JobPlan.testClip(media: media, deflicker: DeflickerSettings(),
                                    encode: EncodeSettings(), start: 600, duration: 60,
                                    filtered: true)
        XCTAssertEqual(plan.outputURL.pathExtension, "mp4")
        XCTAssertTrue(plan.args.contains("-an"), "A/B clips are muted video-only (ADR-8)")
        XCTAssertEqual(plan.totalFrames, 1439) // 60 s × 23.976 rounded
        let joined = plan.args.joined(separator: " ")
        XCTAssertTrue(joined.contains("-ss 600.000000 -t 60.000000 -i"), "-ss before -i (fast seek)")
    }

    func testTimestampParsing() {
        XCTAssertEqual(AppModel.parse(timestamp: "10:00"), 600)
        XCTAssertEqual(AppModel.parse(timestamp: "1:02:03"), 3723)
        XCTAssertEqual(AppModel.parse(timestamp: "90"), 90)
        XCTAssertNil(AppModel.parse(timestamp: "abc"))
        XCTAssertNil(AppModel.parse(timestamp: "1:2:3:4"))
        XCTAssertEqual(AppModel.format(seconds: 600), "10:00")
        XCTAssertEqual(AppModel.format(seconds: 3723), "1:02:03")
    }
}

final class ProbeParseTests: XCTestCase {
    func testMKVShapeWithNAStreamFields() throws {
        // mirrors real ffprobe output for the test scan: no nb_frames/duration on streams
        let json = """
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"h264","width":1440,"height":1080,
           "pix_fmt":"yuv420p","avg_frame_rate":"24000/1001","r_frame_rate":"24000/1001",
           "color_range":"tv","color_space":"bt709","color_transfer":"unknown"},
          {"index":1,"codec_type":"audio","codec_name":"pcm_s16be","channels":2,"sample_rate":"48000"}],
         "format":{"duration":"5491.528000","size":"25239465137"}}
        """.data(using: .utf8)!
        let info = try Probe.parse(data: json, url: URL(fileURLWithPath: "/tmp/x.mkv"))
        XCTAssertEqual(info.totalFrames, 131_665)
        XCTAssertEqual(info.colorSpace, "bt709")
        XCTAssertNil(info.colorTransfer, "\"unknown\" must normalize to nil")
        XCTAssertEqual(info.audioTracks.first?.codec, "pcm_s16be")
    }
}

final class VpyTemplateTests: XCTestCase {
    private let scripts = URL(fileURLWithPath: "/tmp/scripts")
    private var src: URL { URL(fileURLWithPath: "/tmp/My \"Scan\" [Encode].mkv") }

    func testFullChainOrderIsFixed() {
        var scratch = ScratchSettings(); scratch.enabled = true
        var dirt = DirtSettings(); dirt.enabled = true
        let vpy = VpyTemplate.render(source: src, trimRange: nil,
                                     deflicker: DeflickerSettings(), scratch: scratch,
                                     dirt: dirt, scriptsDir: scripts)
        // validated order: deflicker → scratch → dirt (CLAUDE.md, do not re-derive)
        let d = vpy.range(of: "deflicker(clip")!.lowerBound
        let s = vpy.range(of: "descratch.DeScratch")!.lowerBound
        let r = vpy.range(of: "RestoreMotionBlocks")!.lowerBound
        XCTAssertLessThan(d, s)
        XCTAssertLessThan(s, r)
        XCTAssertTrue(vpy.contains("core.bs.VideoSource"))
        XCTAssertTrue(vpy.hasSuffix("clip.set_output()\n"))
    }

    func testQuotedPathEscaping() {
        let vpy = VpyTemplate.render(source: src, trimRange: 100..<200,
                                     deflicker: DeflickerSettings(),
                                     scratch: ScratchSettings(), dirt: DirtSettings(),
                                     scriptsDir: scripts)
        XCTAssertTrue(vpy.contains(#"My \"Scan\" [Encode].mkv"#))
        XCTAssertTrue(vpy.contains("clip = clip[100:200]"))
    }

    func testDisabledStagesAbsent() {
        let vpy = VpyTemplate.render(source: src, trimRange: nil,
                                     deflicker: DeflickerSettings(),
                                     scratch: ScratchSettings(), dirt: DirtSettings(),
                                     scriptsDir: scripts)
        XCTAssertFalse(vpy.contains("DeScratch"))
        XCTAssertFalse(vpy.contains("RestoreMotionBlocks"))
        XCTAssertFalse(vpy.contains("spotless"))
        XCTAssertTrue(vpy.contains("deflicker(clip"), "deflicker on by default")
    }

    func testSpotLessEngineAndMarkMode() {
        var scratch = ScratchSettings(); scratch.enabled = true; scratch.markOnly = true
        scratch.maxwidth = 4 // even input must be coerced odd (plugin constraint)
        var dirt = DirtSettings(); dirt.enabled = true; dirt.engine = .spotLess; dirt.radT = 2
        let vpy = VpyTemplate.render(source: src, trimRange: nil,
                                     deflicker: DeflickerSettings(), scratch: scratch,
                                     dirt: dirt, scriptsDir: scripts)
        XCTAssertTrue(vpy.contains("mark=True"))
        XCTAssertTrue(vpy.contains("maxwidth=5"))
        XCTAssertTrue(vpy.contains("spotless(clip, radT=2"))
        XCTAssertFalse(vpy.contains("RestoreMotionBlocks"))
    }

    func testBackendRouting() {
        XCTAssertFalse(VpyTemplate.needsVapourSynth(scratch: ScratchSettings(), dirt: DirtSettings()))
        var s = ScratchSettings(); s.enabled = true
        XCTAssertTrue(VpyTemplate.needsVapourSynth(scratch: s, dirt: DirtSettings()))
    }
}

final class MultiPassAndSideBySideTests: XCTestCase {
    func testFfmpegFilterChainRepetition() {
        let d = DeflickerSettings()
        XCTAssertEqual(JobPlan.filterChain(d, passes: 1), "deflicker=mode=pm:size=10")
        XCTAssertEqual(JobPlan.filterChain(d, passes: 2),
                       "deflicker=mode=pm:size=10,deflicker=mode=pm:size=10")
        XCTAssertEqual(JobPlan.filterChain(d, passes: 7).components(separatedBy: ",").count, 3,
                       "passes clamp to 3")
    }

    func testVpyPassesLoop() {
        var scratch = ScratchSettings(); scratch.enabled = true
        let vpy = VpyTemplate.render(source: URL(fileURLWithPath: "/tmp/x.mkv"),
                                     trimRange: nil, deflicker: DeflickerSettings(),
                                     scratch: scratch, dirt: DirtSettings(),
                                     scriptsDir: URL(fileURLWithPath: "/tmp/s"), passes: 3)
        XCTAssertTrue(vpy.contains("for _ in range(3):"))
        XCTAssertTrue(vpy.contains("def _restore(clip):"))
        // chain body appears once (inside the function), applied N times by the loop
        XCTAssertEqual(vpy.components(separatedBy: "DeScratch").count - 1, 1)
    }

    func testQuickSampleSegments() {
        var rng = SystemRandomNumberGenerator()
        let segs = SideBySide.quickSampleSegments(duration: 5491.5, using: &rng)
        XCTAssertEqual(segs.count, 6)
        for s in segs {
            XCTAssertGreaterThanOrEqual(s.start, 15.0 - 0.001)
            XCTAssertLessThanOrEqual(s.start + s.duration, 5491.5 - 15.0 + 0.001)
            XCTAssertEqual(s.duration, 10)
        }
        // strictly increasing, non-overlapping
        for (a, b) in zip(segs, segs.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.start, a.start + a.duration - 0.001)
        }
        XCTAssertEqual(segs.reduce(0.0) { $0 + $1.duration }, 60.0, "6×10 s = 1 min reel")
    }

    func testQuickSampleShortFile() {
        var rng = SystemRandomNumberGenerator()
        let segs = SideBySide.quickSampleSegments(duration: 30, using: &rng)
        XCTAssertEqual(segs.count, 1, "short files degrade to a single segment")
        XCTAssertLessThanOrEqual(segs[0].start + segs[0].duration, 30)
    }

    func testHstackAndConcatArgs() throws {
        let args = SideBySide.hstackArgs(a: URL(fileURLWithPath: "/tmp/a.mp4"),
                                         b: URL(fileURLWithPath: "/tmp/b.mp4"),
                                         quality: 60, output: URL(fileURLWithPath: "/tmp/o.mp4"))
        XCTAssertTrue(args.joined(separator: " ").contains("[0:v][1:v]hstack=inputs=2"))
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("cl.txt")
        try SideBySide.writeConcatList(segments: [URL(fileURLWithPath: "/tmp/it's.mp4")], to: list)
        let body = try String(contentsOf: list, encoding: .utf8)
        XCTAssertTrue(body.contains("file '/tmp/it'\\''s.mp4'"), "single quotes escaped for concat demuxer")
        try? FileManager.default.removeItem(at: list)
    }

    func testSidebySideOutputSuffix() {
        let out = JobPlan.outputURL(for: URL(fileURLWithPath: "/tmp/scan.mkv"),
                                    ext: "mp4", suffix: "sidebyside")
        XCTAssertEqual(out.lastPathComponent, "scan.sidebyside.mp4")
    }
}

final class DebugReportTests: XCTestCase {
    func testReportContainsErrorSettingsAndEnvironment() {
        var scratch = ScratchSettings(); scratch.enabled = true; scratch.maxwidth = 4
        var dirt = DirtSettings(); dirt.enabled = true; dirt.engine = .spotLess
        let media = MediaInfo(url: URL(fileURLWithPath: "/tmp/scan.mkv"), width: 1440,
                              height: 1080, fpsNum: 24000, fpsDen: 1001,
                              durationSeconds: 100, sizeBytes: 1, videoCodec: "h264",
                              pixFmt: "yuv420p", colorRange: "tv", colorSpace: "bt709",
                              colorPrimaries: nil, colorTransfer: nil, audioTracks: [])
        let r = DebugReport.build(error: "ffmpeg exited with status 234",
                                  failedJob: "Side-by-side 2/6: stacking…",
                                  media: media, deflicker: DeflickerSettings(),
                                  scratch: scratch, dirt: dirt,
                                  encode: EncodeSettings(), passes: 2)
        XCTAssertTrue(r.contains("ffmpeg exited with status 234"))
        XCTAssertTrue(r.contains("Side-by-side 2/6"))
        XCTAssertTrue(r.contains("passes: 2"))
        XCTAssertTrue(r.contains("maxwidth=5"), "reports the coerced odd value actually used")
        XCTAssertTrue(r.contains("engine=spotLess"))
        XCTAssertTrue(r.contains("1440x1080"))
        XCTAssertTrue(r.contains("space=bt709"))
        XCTAssertTrue(r.contains("ffmpeg:"), "environment section present")
    }
}
