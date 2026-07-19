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
        let r = vpy.range(of: "maskclean(clip")!.lowerBound
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
                                     scratch: .off, dirt: .off,
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

    func testDefaultsEnableFullChain() {
        XCTAssertTrue(ScratchSettings().enabled)
        XCTAssertTrue(DirtSettings().enabled)
        XCTAssertTrue(DeflickerSettings().enabled)
        XCTAssertTrue(VpyTemplate.needsVapourSynth(scratch: ScratchSettings(),
                                                   dirt: DirtSettings()))
    }

    func testDirtEngineRendering() {
        var dirt = DirtSettings(); dirt.strength = 12
        dirt.engine = .removeDirtMC
        let mc = VpyTemplate.render(source: src, trimRange: nil,
                                    deflicker: DeflickerSettings(), scratch: .off,
                                    dirt: dirt, scriptsDir: scripts)
        XCTAssertTrue(mc.contains("from removedirtmc import remove_dirt_mc"))
        XCTAssertTrue(mc.contains("remove_dirt_mc(clip, strength=12)"))
        XCTAssertFalse(mc.contains("RestoreMotionBlocks"), "MC engine lives in the script module")

        dirt.engine = .removeDirt
        let classic = VpyTemplate.render(source: src, trimRange: nil,
                                         deflicker: DeflickerSettings(), scratch: .off,
                                         dirt: dirt, scriptsDir: scripts)
        XCTAssertTrue(classic.contains("RestoreMotionBlocks(restore, clip"))
        XCTAssertTrue(classic.contains("noise=12"), "strength feeds classic noise limit")

        dirt.engine = .spotLess
        let spot = VpyTemplate.render(source: src, trimRange: nil,
                                      deflicker: DeflickerSettings(), scratch: .off,
                                      dirt: dirt, scriptsDir: scripts)
        XCTAssertTrue(spot.contains("tm=False"), "truemotion off by default")
    }

    func testBackendRouting() {
        XCTAssertFalse(VpyTemplate.needsVapourSynth(scratch: .off, dirt: .off))
        var s = ScratchSettings(); s.enabled = true
        XCTAssertTrue(VpyTemplate.needsVapourSynth(scratch: s, dirt: .off))
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

    func testOneShotAndConcatArgs() throws {
        // ffmpeg-only path: single generation — split source, filter one branch
        let args = SideBySide.oneShotArgs(source: URL(fileURLWithPath: "/tmp/s.mkv"),
                                          start: 60, duration: 10,
                                          filterChain: "deflicker=mode=pm:size=10,deflicker=mode=pm:size=10",
                                          quality: 60, output: URL(fileURLWithPath: "/tmp/o.mp4"))
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("[0:v]split[a][b];[b]deflicker=mode=pm:size=10,deflicker=mode=pm:size=10[f];[a][f]hstack=inputs=2:shortest=1"))
        XCTAssertEqual(joined.components(separatedBy: "-c:v").count - 1, 1, "exactly one encode")
        // VS path: vpy outputs the stacked pair; ffmpeg only encodes y4m
        let vs = SideBySide.vsEncodeArgs(quality: 60,
                                         output: URL(fileURLWithPath: "/tmp/o.mp4")).joined(separator: " ")
        XCTAssertTrue(vs.contains("-f yuv4mpegpipe -i -"))
        XCTAssertFalse(vs.contains("hstack"), "no cross-stream sync in the VS path")
        // and the vpy stacks source+filtered from the SAME decode (exact alignment)
        var sc = ScratchSettings(); sc.enabled = true
        let vpy = VpyTemplate.render(source: URL(fileURLWithPath: "/tmp/s.mkv"),
                                     trimRange: 100..<200, deflicker: DeflickerSettings(),
                                     scratch: sc, dirt: DirtSettings(),
                                     scriptsDir: URL(fileURLWithPath: "/tmp"), sideBySide: true)
        XCTAssertTrue(vpy.contains("source_half = clip"))
        XCTAssertTrue(vpy.contains("core.std.StackHorizontal([source_half, clip])"))
        let trimIdx = vpy.range(of: "clip = clip[100:200]")!.lowerBound
        let halfIdx = vpy.range(of: "source_half = clip")!.lowerBound
        XCTAssertLessThan(trimIdx, halfIdx, "source half captured after trim, before filters")
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

final class SizeEstimateTests: XCTestCase {
    func testQualityCurveMatchesMeasurements() {
        let e60 = EncodeSettings()
        // S3 measurement: q60 -> ~2.5 Mbps at 1440x1080
        XCTAssertEqual(e60.estimatedBytesPerSecond(width: 1440, height: 1080),
                       2.5e6 / 8, accuracy: 1000)
        var e100 = EncodeSettings(); e100.quality = 100
        // field measurement 2026-07-17: q100 10 s clip ≈ 184 MB -> ~18 MB/s
        let q100 = e100.estimatedBytesPerSecond(width: 1440, height: 1080)
        XCTAssertGreaterThan(q100, 15e6)
        XCTAssertLessThan(q100, 30e6)
    }

    func testFullMovieEstimateScales() {
        let m = MediaInfo(url: URL(fileURLWithPath: "/tmp/x.mkv"), width: 1440,
                          height: 1080, fpsNum: 24000, fpsDen: 1001,
                          durationSeconds: 5491.5, sizeBytes: 0, videoCodec: "h264",
                          pixFmt: "yuv420p", colorRange: nil, colorSpace: nil,
                          colorPrimaries: nil, colorTransfer: nil, audioTracks: [])
        XCTAssertEqual(Double(m.estimatedOutputBytes(quality: 60)),
                       5491.5 * 2.5e6 / 8, accuracy: 1e6)     // ~1.7 GB
        XCTAssertGreaterThan(m.estimatedOutputBytes(quality: 100),
                             80_000_000_000 / 8)              // q100 full movie > 10 GB
    }
}

final class DiffColumnTests: XCTestCase {
    func testVpyDiffColumn() {
        var sc = ScratchSettings(); sc.enabled = true
        let vpy = VpyTemplate.render(source: URL(fileURLWithPath: "/tmp/s.mkv"),
                                     trimRange: 0..<100, deflicker: DeflickerSettings(),
                                     scratch: sc, dirt: DirtSettings(),
                                     scriptsDir: URL(fileURLWithPath: "/tmp"),
                                     sideBySide: true, diffColumn: true)
        XCTAssertTrue(vpy.contains(#"["x y - abs 8 *", _neutral, _neutral]"#))
        XCTAssertTrue(vpy.contains("StackHorizontal([source_half, clip, _diff])"))
    }

    func testOneShotDiffGraph() {
        let joined = SideBySide.oneShotArgs(source: URL(fileURLWithPath: "/tmp/s.mkv"),
                                            start: 0, duration: 10,
                                            filterChain: "deflicker=mode=pm:size=10",
                                            quality: 60,
                                            output: URL(fileURLWithPath: "/tmp/o.mp4"),
                                            diffColumn: true).joined(separator: " ")
        XCTAssertTrue(joined.contains("split=3[a][b][c]"))
        XCTAssertTrue(joined.contains("blend=all_mode=difference"))
        XCTAssertTrue(joined.contains("hstack=inputs=3:shortest=1"))
        XCTAssertEqual(joined.components(separatedBy: "-c:v").count - 1, 1, "still one encode")
    }
}

final class MaskCleanTests: XCTestCase {
    private let scripts = URL(fileURLWithPath: "/tmp/scripts")
    private var src: URL { URL(fileURLWithPath: "/tmp/scan.mkv") }

    func testMaskCleanIsDefaultAndRenders() {
        XCTAssertEqual(DirtSettings().engine, .maskClean)
        var dirt = DirtSettings(); dirt.mcSensitivity = 20
        dirt.mcPolarity = .dark; dirt.mcMaxSize = 800
        let vpy = VpyTemplate.render(source: src, trimRange: nil,
                                     deflicker: DeflickerSettings(), scratch: .off,
                                     dirt: dirt, scriptsDir: scripts)
        XCTAssertTrue(vpy.contains("from maskclean import maskclean"))
        XCTAssertTrue(vpy.contains(#"maskclean(clip, t1=20, polarity="dark", max_size=800)"#))
        XCTAssertFalse(vpy.contains("preview_mask"))
        dirt.mcShowMask = true
        let preview = VpyTemplate.render(source: src, trimRange: nil,
                                         deflicker: DeflickerSettings(), scratch: .off,
                                         dirt: dirt, scriptsDir: scripts)
        XCTAssertTrue(preview.contains("preview_mask=True"))
    }
}

final class AnimationSafetyTests: XCTestCase {
    private let scripts = URL(fileURLWithPath: "/tmp/scripts")
    private var src: URL { URL(fileURLWithPath: "/tmp/scan.mkv") }

    func testScratchPolarityRendersModeY() {
        var sc = ScratchSettings()
        XCTAssertEqual(sc.polarity, .both, "app default covers both polarities")
        sc.polarity = .bright
        let vpy = VpyTemplate.render(source: src, trimRange: nil,
                                     deflicker: DeflickerSettings(), scratch: sc,
                                     dirt: .off, scriptsDir: scripts)
        XCTAssertTrue(vpy.contains("modey=2"), "bright-only shields dark ink lines")
    }

    func testAnimatedPresetIsInkSafe() {
        let anim = Preset.all.first { $0.id == "anim" }!
        XCTAssertEqual(anim.scratch.polarity, .bright)
        XCTAssertTrue(anim.dirt.mcProtectDark)
        XCTAssertEqual(anim.dirt.engine, .maskClean)
    }

    func testMLProtectDarkRenders() {
        var dirt = DirtSettings(); dirt.mcProtectDark = true
        let vpy = VpyTemplate.render(source: src, trimRange: nil,
                                     deflicker: DeflickerSettings(), scratch: .off,
                                     dirt: dirt, scriptsDir: scripts,
                                     mlMaskPath: "/tmp/mask.mkv")
        XCTAssertTrue(vpy.contains("ml_protect_dark=True"))
        XCTAssertTrue(vpy.contains("ml_mask=_ml"))
    }
}
