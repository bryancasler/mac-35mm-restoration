import CryptoKit
import Foundation

/// Downloads the pinned prebuilt plugins (after explicit user approval in the
/// setup UI), verifies sha256 against the manifest, extracts the dylib into the
/// app-managed plugin dir (ADR-6 — never Homebrew's tree). DeScratch is built
/// from source (meson) because no prebuilt exists (S2).
enum ProvisionError: LocalizedError {
    case download(String, Int)
    case checksumMismatch(String, expected: String, got: String)
    case extraction(String)
    case buildFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .download(let name, let code):
            return "\(name): download failed (HTTP \(code))"
        case .checksumMismatch(let name, let expected, let got):
            return "\(name): sha256 mismatch — expected \(expected.prefix(12))…, got \(got.prefix(12))… (refusing to install)"
        case .extraction(let name):
            return "\(name): could not extract dylib from archive"
        case .buildFailed(let step, let tail):
            return "DeScratch build failed at \(step):\n…\(tail)"
        }
    }
}

final class PluginProvisioner {
    var onStatus: ((String) -> Void)?

    private var pluginDir: URL { DependencyDetector.pluginDir }

    /// Fetch + verify + install all manifest plugins. Throws on the first failure.
    func provisionPrebuilts() async throws {
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        var manifestLines: [String] = []
        for spec in PluginSpec.all {
            onStatus?("Downloading \(spec.id)…")
            let (data, response) = try await URLSession.shared.data(from: spec.url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { throw ProvisionError.download(spec.id, code) }

            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == spec.sha256 else {
                throw ProvisionError.checksumMismatch(spec.id, expected: spec.sha256, got: digest)
            }

            onStatus?("Installing \(spec.id)…")
            try extractDylib(zipData: data, spec: spec)
            manifestLines.append("\(digest)  \(spec.url.lastPathComponent)")
        }
        try manifestLines.joined(separator: "\n").appending("\n")
            .write(to: pluginDir.appendingPathComponent("manifest.sha256"),
                   atomically: true, encoding: .utf8)
        onStatus?("Prebuilt plugins installed")
    }

    private func extractDylib(zipData: Data, spec: PluginSpec) throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilmRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zipURL = work.appendingPathComponent("plugin.zip")
        try zipData.write(to: zipURL)
        let status = runSync("/usr/bin/unzip", ["-o", "-q", zipURL.path, "-d", work.path]).status
        guard status == 0 else { throw ProvisionError.extraction(spec.id) }

        guard let dylib = findFile(named: { $0.hasSuffix(".dylib") }, under: work) else {
            throw ProvisionError.extraction(spec.id)
        }
        let dest = pluginDir.appendingPathComponent(spec.dylib)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: dylib, to: dest)
    }

    /// MVTools source build (dubhater master, meson): the only darwin-aarch64
    /// prebuilt (v24) silently returns input frames unchanged from
    /// Compensate/Flow on VS R77 — the doctor's no-op canary guards this.
    func buildMVTools() async throws {
        try await mesonBuild(name: "MVTools", repo: PluginSpec.mvtoolsRepo,
                             dylib: PluginSpec.mvtoolsDylib)
    }

    /// DeScratch source build — the S2-proven recipe (build-descratch.sh as code).
    func buildDeScratch() async throws {
        try await mesonBuild(name: "DeScratch", repo: PluginSpec.descratchRepo,
                             dylib: PluginSpec.descratchDylib, recurseSubmodules: true)
    }

    private func mesonBuild(name: String, repo: String, dylib: String,
                            recurseSubmodules: Bool = false) async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilmRestore-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var cloneArgs = ["clone", "--depth", "1"]
        if recurseSubmodules { cloneArgs += ["--recurse-submodules", "--shallow-submodules"] }
        cloneArgs += [repo, work.appendingPathComponent("src").path]
        let steps: [(String, String, [String])] = [
            ("clone", "/usr/bin/git", cloneArgs),
            ("meson setup", Tools.brewBin + "/meson",
             ["setup", work.appendingPathComponent("src/build").path,
              work.appendingPathComponent("src").path, "--buildtype=release"]),
            ("ninja", Tools.brewBin + "/ninja",
             ["-C", work.appendingPathComponent("src/build").path]),
        ]
        for (step, tool, args) in steps {
            onStatus?("\(name): \(step)…")
            // meson needs brew's pkgconf on PATH to find fftw etc.
            let r = runSync(tool, args, extraPath: Tools.brewBin)
            guard r.status == 0 else {
                throw ProvisionError.buildFailed("\(name) \(step)", String(r.output.suffix(600)))
            }
        }
        guard let built = findFile(named: { $0.hasSuffix(".dylib") },
                                   under: work.appendingPathComponent("src/build")) else {
            throw ProvisionError.buildFailed("\(name) locate dylib", "no .dylib in build dir")
        }
        let dest = pluginDir.appendingPathComponent(dylib)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: built, to: dest)
        _ = runSync("/usr/bin/install_name_tool", ["-id", "@loader_path/\(dest.lastPathComponent)", dest.path])
        _ = runSync("/usr/bin/codesign", ["-s", "-", "-f", dest.path])
        onStatus?("\(name) built and installed")
    }

    // MARK: helpers

    private func findFile(named match: (String) -> Bool, under dir: URL) -> URL? {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let f = e?.nextObject() as? URL {
            if match(f.lastPathComponent) { return f }
        }
        return nil
    }

    @discardableResult
    private func runSync(_ tool: String, _ args: [String],
                         extraPath: String? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let extraPath {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(extraPath):\(env["PATH"] ?? "/usr/bin:/bin")"
            p.environment = env
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "could not launch \(tool)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
