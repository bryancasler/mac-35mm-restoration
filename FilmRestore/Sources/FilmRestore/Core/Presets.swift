import Foundation

/// M5 presets — one-click starting points; every control stays adjustable after.
struct Preset: Identifiable {
    let id: String
    let name: String
    let note: String
    let deflicker: DeflickerSettings
    let scratch: ScratchSettings
    let dirt: DirtSettings

    static let all: [Preset] = [
        Preset(
            id: "35mm",
            name: "35mm scan",
            note: "Deflicker + vertical scratch removal + dirt removal — the full validated chain",
            deflicker: DeflickerSettings(),               // pm / size 10
            scratch: {
                var s = ScratchSettings(); s.enabled = true; return s
            }(),
            dirt: {
                var d = DirtSettings(); d.enabled = true; return d   // RemoveDirt defaults
            }()),
        Preset(
            id: "8mm",
            name: "8mm home movie",
            note: "Strong deflicker + dirt removal; scratch removal off (8mm damage is rarely straight vertical lines)",
            deflicker: {
                var d = DeflickerSettings(); d.size = 19; return d   // small-gauge flicker is worse
            }(),
            scratch: ScratchSettings(),
            dirt: {
                var d = DirtSettings(); d.enabled = true; return d
            }()),
        Preset(
            id: "vhs",
            name: "VHS capture",
            note: "Deflicker only — film dirt/scratch filters would eat tape artifacts",
            deflicker: DeflickerSettings(),
            scratch: ScratchSettings(),
            dirt: DirtSettings()),
    ]
}
