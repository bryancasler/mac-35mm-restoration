import Foundation

/// Persistent settings (UI/UX revision): last-used globals restored at launch,
/// plus a per-film sidecar (`<source>.filmrestore.json`) so every scan reopens
/// exactly where tuning left off. The sidecar is a NEW file beside the source —
/// the never-touch-source rule concerns the video file itself.
struct SettingsBundle: Codable, Equatable {
    var version = 1
    var deflicker: DeflickerSettings
    var scratch: ScratchSettings
    var dirt: DirtSettings
    var encode: EncodeSettings
    var passes: Int
    var sbsDiffColumn: Bool
    var showFrameCounter: Bool?   // optional so older settings files still decode
}

enum SettingsStore {
    static var globalURL: URL {
        AppDirs.appSupport.appendingPathComponent("settings.json")
    }

    static func sidecarURL(for source: URL) -> URL {
        URL(fileURLWithPath: source.path + ".filmrestore.json")
    }

    static func load(from url: URL) -> SettingsBundle? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SettingsBundle.self, from: data)
    }

    static func save(_ bundle: SettingsBundle, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle) else { return }
        try? data.write(to: url, options: .atomic)
    }
}


/// Metadata for the last-rendered A/B clip pair — lets the player window work
/// across relaunches and carry the absolute frame offset without baking
/// anything into the video files.
struct ClipsMeta: Codable, Equatable {
    var aPath: String
    var bPath: String
    var startFrame: Int
    var fpsNum: Int
    var fpsDen: Int
    var sourcePath: String

    static var url: URL { AppDirs.testClips.appendingPathComponent("clips.meta.json") }

    static func load() -> ClipsMeta? {
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(ClipsMeta.self, from: data),
              FileManager.default.fileExists(atPath: meta.aPath),
              FileManager.default.fileExists(atPath: meta.bPath) else { return nil }
        return meta
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
