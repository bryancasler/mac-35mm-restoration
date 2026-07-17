import Foundation

/// M3 detection: what's installed, what's missing, what to run (ADR-6).
struct DependencyStatus {
    enum State: Equatable {
        case ok(String)       // detail, e.g. version
        case missing(String)  // remedy, e.g. brew command
    }

    var ffmpeg: State = .missing("brew install ffmpeg")
    var vapoursynth: State = .missing("brew install vapoursynth")
    var bestsource: State = .missing("brew install vapoursynth-bestsource")
    var mesonNinja: State = .missing("brew install meson ninja")
    var plugins: [String: Bool] = [:]   // dylib name → present
    var descratch = false

    var coreOK: Bool {
        if case .ok = ffmpeg { return true }
        return false
    }
    var vsStackOK: Bool {
        guard case .ok = vapoursynth, case .ok = bestsource else { return false }
        return pluginsOK && descratch
    }
    var pluginsOK: Bool { plugins.values.allSatisfy { $0 } && !plugins.isEmpty }
}

enum DependencyDetector {
    static let vspipe = Tools.brewBin + "/vspipe"
    static var pluginDir: URL { AppDirs.appSupport.appendingPathComponent("plugins") }

    static func detect() -> DependencyStatus {
        var s = DependencyStatus()

        if Tools.isInstalled(Tools.ffmpeg), let v = Tools.versionLine(of: Tools.ffmpeg) {
            s.ffmpeg = .ok(v.components(separatedBy: " Copyright").first ?? v)
        }
        if Tools.isInstalled(vspipe), let v = vspipeCore() {
            s.vapoursynth = .ok(v)
        }
        // Homebrew puts bestsource under the formula's site-packages, whose
        // pythonX.Y segment moves on Python bumps (ADR-6) — search the stable
        // opt symlink instead of hardcoding the full path.
        let bsRoot = "/opt/homebrew/opt/vapoursynth-bestsource"
        if let e = FileManager.default.enumerator(atPath: bsRoot),
           e.contains(where: { ($0 as? String)?.hasSuffix("libbestsource.dylib") == true }) {
            s.bestsource = .ok("libbestsource.dylib present")
        }
        if Tools.isInstalled(Tools.brewBin + "/meson"),
           Tools.isInstalled(Tools.brewBin + "/ninja") {
            s.mesonNinja = .ok("meson + ninja present")
        }

        for spec in PluginSpec.all {
            s.plugins[spec.dylib] = FileManager.default.fileExists(
                atPath: pluginDir.appendingPathComponent(spec.dylib).path)
        }
        s.descratch = FileManager.default.fileExists(
            atPath: pluginDir.appendingPathComponent(PluginSpec.descratchDylib).path)
        return s
    }

    /// "Core R77" from `vspipe --version`.
    private static func vspipeCore() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: vspipe)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("Core") }.map(String.init)
    }
}
