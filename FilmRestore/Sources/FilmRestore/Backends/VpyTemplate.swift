import Foundation

/// M4 restoration-filter settings (validated pipeline order is fixed:
/// deflicker → scratch → dirt; each stage independently toggleable).
struct ScratchSettings: Equatable {
    var enabled = false
    var mindif = 5          // 1...255, detection threshold
    var asym = 10
    var maxgap = 3
    var maxwidth = 3        // ODD 1...15 (plugin constraint, S2)
    var minlen = 100
    var maxangle = 3.0
    var markOnly = false    // DeScratch mark mode: highlight, don't fix

    var oddMaxwidth: Int { maxwidth | 1 }  // UI safety: force odd
}

struct DirtSettings: Equatable {
    var enabled = false
    var engine: Engine = .removeDirt

    // RemoveDirt strength (default engine, ADR-12)
    var gmthreshold = 80    // global-motion % threshold
    var mthreshold = 160    // block motion threshold

    // SpotLess strength (advanced engine)
    var thsad = 10_000
    var radT = 1            // 1...3

    enum Engine: String, CaseIterable, Identifiable {
        case removeDirt, spotLess
        var id: String { rawValue }
        var label: String {
            self == .removeDirt ? "RemoveDirt (default)" : "SpotLess (motion-compensated, slower)"
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
                       diffColumn: Bool = false) -> String {
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
                      + "maxangle=\(scratch.maxangle)\(mark))")
        }
        if dirt.enabled {
            switch dirt.engine {
            case .removeDirt:
                // classic composition, zsmooth-only (S2: no RGVS needed)
                body += [
                    "cleansed = core.zsmooth.Clense(clip)",
                    "sbegin = core.zsmooth.ForwardClense(clip)",
                    "send = core.zsmooth.BackwardClense(clip)",
                    "scsel = core.removedirt.SCSelect(clip, sbegin, send, cleansed)",
                    "alt = core.zsmooth.Repair(scsel, clip, mode=[16, 16, 1])",
                    "restore = core.zsmooth.Repair(cleansed, clip, mode=[16, 16, 1])",
                    "clip = core.removedirt.RestoreMotionBlocks(clip, restore, neighbour=scsel, "
                        + "alternative=alt, gmthreshold=\(dirt.gmthreshold), "
                        + "mthreshold=\(dirt.mthreshold), dist=1, noise=10, noisy=12)",
                ]
            case .spotLess:
                lines.append("from spotless import spotless")
                body.append("clip = spotless(clip, radT=\(dirt.radT), thsad=\(dirt.thsad))")
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
