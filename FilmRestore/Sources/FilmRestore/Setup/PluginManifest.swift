import Foundation

/// Pinned plugin manifest (ADR-6): exact release-asset URLs + sha256, verified
/// working in spike S2 on 2026-07-17. Every download is listed on the setup
/// screen and requires explicit user approval before anything is fetched.
struct PluginSpec: Identifiable {
    let id: String            // display name
    let dylib: String         // installed filename
    let url: URL
    let sha256: String
    let note: String

    // MVTools is NOT in this prebuilt list: the only darwin-aarch64 prebuilt
    // (v24) silently no-ops Compensate/Flow on VapourSynth R77 — discovered
    // 2026-07-18, see docs/research + ADR-6 amendment. It is built from
    // source (dubhater master, meson) like DeScratch.
    static let all: [PluginSpec] = [
        PluginSpec(
            id: "RemoveDirt v1.1",
            dylib: "libremovedirt.dylib",
            url: URL(string: "https://github.com/Stefan-Olt/vs-plugin-build/releases/download/vsplugin/com.vapoursynth.removedirt/v1.1/darwin-aarch64/2026-01-07T00.39.06%2B00.00Z/RemoveDirt-v1.1-darwin-aarch64.zip")!,
            sha256: "cfabfe06f6bc942c4cc923a8112800134af2df5431454b38806f3ff26dc78ea7",
            note: "dirt removal (default engine, ADR-12)"),
        PluginSpec(
            id: "TemporalMedian v1",
            dylib: "libtemporalmedian.dylib",
            url: URL(string: "https://github.com/Stefan-Olt/vs-plugin-build/releases/download/vsplugin/com.nodame.temporalmedian/v1/darwin-aarch64/2024-09-30T20.56.40%2B00.00Z/TemporalMedian-v1-darwin-aarch64.zip")!,
            sha256: "05eb41d2961703bd86b7e8423efdbfc5c75e163a232794394f57acb1b4052018",
            note: "temporal median (SpotLess spare provider)"),
        PluginSpec(
            id: "zsmooth 0.19.0",
            dylib: "libzsmooth.dylib",
            url: URL(string: "https://github.com/adworacz/zsmooth/releases/download/0.19.0/zsmooth-aarch64-macos.zip")!,
            sha256: "be40bcf7777a2d929d480dff1ae55402a3f7b793560a1a66a12ce17a7d321c4b",
            note: "Clense/Repair/TemporalMedian (NEON)"),
    ]

    /// DeScratch has no prebuilt anywhere (S2) — meson source build.
    static let descratchDylib = "libdescratch.dylib"
    static let descratchRepo = "https://github.com/vapoursynth/descratch.git"

    /// MVTools: source build (see note above). Needs fftw + pkgconf from brew.
    static let mvtoolsDylib = "libmvtools.dylib"
    static let mvtoolsRepo = "https://github.com/dubhater/vapoursynth-mvtools.git"
}
