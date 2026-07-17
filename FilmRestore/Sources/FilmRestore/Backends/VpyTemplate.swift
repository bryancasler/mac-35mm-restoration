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
    static func render(source: URL,
                       trimRange: Range<Int>?,
                       deflicker: DeflickerSettings,
                       scratch: ScratchSettings,
                       dirt: DirtSettings,
                       scriptsDir: URL) -> String {
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
        if deflicker.enabled {
            lines.append("from deflicker import deflicker")
            lines.append("clip = deflicker(clip, size=\(deflicker.size), mode=\(pyString(deflicker.mode.rawValue)))")
        }
        if scratch.enabled {
            let mark = scratch.markOnly ? ", mark=True" : ""
            lines.append("clip = core.descratch.DeScratch(clip, mindif=\(scratch.mindif), "
                       + "asym=\(scratch.asym), maxgap=\(scratch.maxgap), "
                       + "maxwidth=\(scratch.oddMaxwidth), minlen=\(scratch.minlen), "
                       + "maxangle=\(scratch.maxangle)\(mark))")
        }
        if dirt.enabled {
            switch dirt.engine {
            case .removeDirt:
                // classic composition, zsmooth-only (S2: no RGVS needed)
                lines += [
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
                lines.append("clip = spotless(clip, radT=\(dirt.radT), thsad=\(dirt.thsad))")
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
