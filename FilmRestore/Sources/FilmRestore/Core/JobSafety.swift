import Foundation

/// ADR-10: refuse to start when the estimated output exceeds free space.
enum DiskGuard {
    /// Free space (importantUsage — what the system will actually let us write).
    static func availableBytes(for url: URL) -> Int64 {
        let values = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// True when writing `estimatedBytes` at `destination` is safe (with 10% headroom).
    static func hasRoom(estimatedBytes: Int64, destination: URL) -> Bool {
        availableBytes(for: destination) > Int64(Double(estimatedBytes) * 1.1)
    }
}

/// ADR-10: keep the machine awake for the duration of a job (caffeinate-equivalent).
final class SleepPreventer {
    private var activity: NSObjectProtocol?

    func begin(reason: String) {
        end()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: reason)
    }

    func end() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    deinit { end() }
}

/// Per-job log file in ~/Library/Logs/FilmRestore/ (ADR-9/10).
final class JobLog {
    let url: URL
    private let handle: FileHandle?
    private let formatter: DateFormatter

    init(jobName: String) {
        AppDirs.ensureAll()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        url = AppDirs.logs.appendingPathComponent("\(stamp)_\(jobName).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func line(_ text: String) {
        let entry = "[\(formatter.string(from: Date()))] \(text)\n"
        handle?.write(entry.data(using: .utf8)!)
    }

    func close() {
        try? handle?.close()
    }
}
