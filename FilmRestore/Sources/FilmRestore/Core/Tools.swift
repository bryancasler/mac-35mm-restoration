import Foundation

/// Locations and health of the external CLI tools (ADR-1: shell-out only).
enum Tools {
    static let brewBin = "/opt/homebrew/bin"
    static var ffmpeg: String { brewBin + "/ffmpeg" }
    static var ffprobe: String { brewBin + "/ffprobe" }

    static func isInstalled(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// First line of `<tool> -version`, e.g. "ffmpeg version 8.1.2 ...".
    static func versionLine(of path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").first.map(String.init)
    }
}

/// App-owned directories.
enum AppDirs {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilmRestore")
    }
    static var testClips: URL { appSupport.appendingPathComponent("testclips") }
    static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FilmRestore")
    }

    static func ensureAll() {
        for dir in [appSupport, testClips, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
