import Foundation

/// M4 restoration-filter settings (validated pipeline order is fixed:
/// deflicker → scratch → dirt; each stage independently toggleable).
struct ScratchSettings: Equatable, Codable {
    var enabled = true      // on by default (2026-07-17): the point of the app

    static var off: ScratchSettings {
        var s = ScratchSettings(); s.enabled = false; return s
    }

    var mindif = 5          // 1...255, detection threshold
    var asym = 10
    var maxgap = 8          // was 3 — real scratches break up; measured 2026-07-17
    var maxwidth = 5        // ODD 1...15 (plugin constraint, S2); was 3
    var minlen = 40         // was 100 — that required a 100px continuous run and
                            // detected ~nothing on the real scan (0.0004 mean Δ)
    var maxangle = 5.0      // was 3
    var markOnly = false    // DeScratch mark mode: highlight, don't fix
    var polarity: ScratchPolarity = .both  // plugin default is DARK-only, which
                                           // on animation hunts ink lines

    enum ScratchPolarity: String, CaseIterable, Identifiable, Codable {
        case dark, bright, both
        var id: String { rawValue }
        var modeY: Int { self == .dark ? 1 : self == .bright ? 2 : 3 }
        var label: String {
            switch self {
            case .dark: return "Dark scratches"
            case .bright: return "Bright scratches (safe for line art)"
            case .both: return "Dark + bright"
            }
        }
    }

    var oddMaxwidth: Int { maxwidth | 1 }  // UI safety: force odd
}

struct DirtSettings: Equatable, Codable {
    var enabled = true      // on by default (2026-07-17)

    static var off: DirtSettings {
        var d = DirtSettings(); d.enabled = false; return d
    }

    var engine: Engine = .maskClean

    // RemoveDirt MC / classic strength: the `noise` limit of
    // RestoreMotionBlocks' NPC detector (johnmeyer used 6-30; higher = stronger)
    var strength = 8

    // classic-engine block thresholds (kept for A/B against the old default)
    var gmthreshold = 80    // global-motion % threshold
    var mthreshold = 160    // block motion threshold

    // SpotLess strength (advanced engine)
    var thsad = 10_000
    var radT = 1            // 1...3
    var spotTrueMotion = false  // community consensus: off tracks fast motion better

    // MaskClean (detect→mask→conceal; S6-validated defaults)
    var mcSensitivity = 24      // detector t1: lower = more sensitive (12...40)
    var mcPolarity: Polarity = .both
    var mcMaxSize = 600         // blobs bigger than this are objects, not dirt
    var mcShowMask = false      // red-overlay detection preview
    var mcUseML = false         // AI-assisted scratch masks (BOPBTL U-Net, ADR-14)
    var mcProtectDark = false   // shield dark line art from ML inpaint (animation)

    enum Polarity: String, CaseIterable, Identifiable, Codable {
        case both, dark, bright
        var id: String { rawValue }
        var label: String {
            switch self {
            case .both: return "Dark + bright"
            case .dark: return "Dark only (prints)"
            case .bright: return "Bright only (negative scans)"
            }
        }
    }

    enum Engine: String, CaseIterable, Identifiable, Codable {
        case maskClean, removeDirtMC, removeDirt, spotLess
        var id: String { rawValue }
        var label: String {
            switch self {
            case .maskClean: return "MaskClean (recommended — detect & conceal)"
            case .removeDirtMC: return "RemoveDirt MC (aggressive)"
            case .removeDirt: return "RemoveDirt (classic)"
            case .spotLess: return "SpotLess (median, slower)"
            }
        }
    }
}

/// Generates the job .vpy — same chain the S3 spike proved, parameterized.
enum VpyTemplate {
    /// scriptsDir = directory containing deflicker.py / spotless.py (Bundle.module).
    /// `passes` (1–3) applies the whole filter chain repeatedly inside ONE graph —
    /// no intermediate encode, no generational loss.
    /// `sideBySide`: output StackHorizontal(source, filtered) — both halves come
    /// from the same decode and frame indices, so alignment is exact by
    /// construction (no cross-stream timestamp sync anywhere).
    /// `diffColumn`: append a third column visualizing |source − filtered| on
    /// luma, amplified 8× (black = identical), neutral chroma.
    static func render(source: URL,
                       trimRange: Range<Int>?,
                       deflicker: DeflickerSettings,
                       scratch: ScratchSettings,
                       dirt: DirtSettings,
                       scriptsDir: URL,
                       passes: Int = 1,
                       sideBySide: Bool = false,
                       diffColumn: Bool = false,
                       mlMaskPath: String? = nil) -> String {
        var lines: [String] = [
            "import sys",
            "import vapoursynth as vs",
            "sys.path.insert(0, \(pyString(scriptsDir.path)))",
            "core = vs.core",
            "clip = core.bs.VideoSource(\(pyString(source.path)))",
        ]
        if let r = trimRange {
            lines.append("clip = clip[\(r.lowerBound):\(r.upperBound)]")
        }
        if sideBySide {
            lines.append("source_half = clip")
        }

        var body: [String] = []   // the chain, as a function body
        if deflicker.enabled {
            lines.append("from deflicker import deflicker")
            body.append("clip = deflicker(clip, size=\(deflicker.size), mode=\(pyString(deflicker.mode.rawValue)))")
        }
        if scratch.enabled {
            let mark = scratch.markOnly ? ", mark=True" : ""
            body.append("clip = core.descratch.DeScratch(clip, mindif=\(scratch.mindif), "
                      + "asym=\(scratch.asym), maxgap=\(scratch.maxgap), "
                      + "maxwidth=\(scratch.oddMaxwidth), minlen=\(scratch.minlen), "
                      + "maxangle=\(scratch.maxangle), modey=\(scratch.polarity.modeY)\(mark))")
        }
        if dirt.enabled {
            switch dirt.engine {
            case .maskClean:
                // FilmRestore's own detect→mask→conceal engine (ADR-13):
                // bit-exact passthrough outside the defect mask. S6-validated:
                // static precision 0.97 / recall 0.95; motion 0.54 / 0.70.
                lines.append("from maskclean import maskclean")
                var mlArg = ""
                if let mlMaskPath {
                    let protect = dirt.mcProtectDark ? ", ml_protect_dark=True" : ""
                    // ML mask video is rendered for the SAME frame range as the
                    // trim, so indices align 1:1
                    lines.append("_ml = core.std.ShufflePlanes(core.bs.VideoSource(\(pyString(mlMaskPath))), planes=0, colorfamily=vs.GRAY)")
                    mlArg = ", ml_mask=_ml" + protect
                }
                body.append("clip = maskclean(clip, t1=\(dirt.mcSensitivity), "
                          + "polarity=\(pyString(dirt.mcPolarity.rawValue)), "
                          + "max_size=\(dirt.mcMaxSize)"
                          + (dirt.mcShowMask ? ", preview_mask=True" : "")
                          + mlArg
                          + ")")
            case .removeDirtMC:
                // johnmeyer's RemoveDirtMC (docs/research/1-vs-community.md):
                // motion-compensate BEFORE detection so cleaning keeps working
                // under camera motion. Two-step vector search on a prefiltered
                // super, per-pixel Flow warp of the UNBLURRED frames, then the
                // RemoveDirt composition on the aligned triple.
                lines.append("from removedirtmc import remove_dirt_mc")
                body.append("clip = remove_dirt_mc(clip, strength=\(dirt.strength))")
            case .removeDirt:
                // canonical composition (avisynth.nl/RemoveDirt), zsmooth-only.
                // RestoreMotionBlocks(filtered, restore): the CLEANSED clip goes
                // FIRST; motion blocks are copied from the original INTO it —
                // inverted args silently output the original nearly unchanged.
                body += [
                    "cleansed = core.zsmooth.Clense(clip)",
                    "sbegin = core.zsmooth.ForwardClense(clip)",
                    "send = core.zsmooth.BackwardClense(clip)",
                    "scsel = core.removedirt.SCSelect(clip, sbegin, send, cleansed)",
                    "alt = core.zsmooth.Repair(scsel, clip, mode=[16, 16, 1])",
                    "restore = core.zsmooth.Repair(cleansed, clip, mode=[16, 16, 1])",
                    "clip = core.removedirt.RestoreMotionBlocks(restore, clip, neighbour=alt, "
                        + "gmthreshold=\(dirt.gmthreshold), "
                        + "mthreshold=\(dirt.mthreshold), dist=1, dmode=2, noise=\(dirt.strength), noisy=12)",
                ]
            case .spotLess:
                lines.append("from spotless import spotless")
                body.append("clip = spotless(clip, radT=\(dirt.radT), thsad=\(dirt.thsad), "
                          + "tm=\(dirt.spotTrueMotion ? "True" : "False"))")
            }
        }
        if !body.isEmpty {
            lines.append("def _restore(clip):")
            lines += body.map { "    " + $0 }
            lines.append("    return clip")
            lines.append("for _ in range(\(max(1, min(3, passes)))):")
            lines.append("    clip = _restore(clip)")
        }
        if sideBySide {
            if diffColumn {
                lines.append("_neutral = str(1 << (clip.format.bits_per_sample - 1))")
                lines.append("_diff = core.std.Expr([source_half, clip], "
                           + "[\"x y - abs 8 *\", _neutral, _neutral])")
                lines.append("clip = core.std.StackHorizontal([source_half, clip, _diff])")
            } else {
                lines.append("clip = core.std.StackHorizontal([source_half, clip])")
            }
        }
        lines.append("clip.set_output()")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Python string literal with safe escaping.
    static func pyString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Does this settings combination need the VS backend at all?
    static func needsVapourSynth(scratch: ScratchSettings, dirt: DirtSettings) -> Bool {
        scratch.enabled || dirt.enabled
    }
}
