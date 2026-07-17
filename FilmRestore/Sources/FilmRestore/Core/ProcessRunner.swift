import Foundation

/// Async wrapper around Foundation.Process for the ffmpeg/ffprobe shell-outs.
/// stdout (the -progress stream) and stderr are split CR/LF-aware and streamed
/// to callbacks; full stderr is captured for the per-job log.
final class ProcessRunner {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutSplitter = LineSplitter()
    private let stderrSplitter = LineSplitter()
    private let callbackQueue = DispatchQueue(label: "ProcessRunner.callbacks")

    var onStdoutLine: ((String) -> Void)?
    var onStderrLine: ((String) -> Void)?

    private(set) var capturedStderr = ""

    init(tool: String, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// Runs to completion, streaming lines. Returns exit status.
    /// Cancellation (Task.cancel) sends SIGTERM.
    func run() async throws -> Int32 {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            self.callbackQueue.async {
                if data.isEmpty {
                    self.stdoutSplitter.flush { self.onStdoutLine?($0) }
                } else {
                    self.stdoutSplitter.feed(data) { self.onStdoutLine?($0) }
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            self.callbackQueue.async {
                let handle = { (line: String) in
                    self.capturedStderr += line + "\n"
                    self.onStderrLine?(line)
                }
                if data.isEmpty {
                    self.stderrSplitter.flush(onLine: handle)
                } else {
                    self.stderrSplitter.feed(data, onLine: handle)
                }
            }
        }

        try process.run()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { [weak self] p in
                    guard let self else { return cont.resume(returning: p.terminationStatus) }
                    // drain + detach handlers, then flush remainders in-order
                    self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    self.stderrPipe.fileHandleForReading.readabilityHandler = nil
                    self.callbackQueue.async {
                        let rest = self.stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        self.stdoutSplitter.feed(rest) { self.onStdoutLine?($0) }
                        self.stdoutSplitter.flush { self.onStdoutLine?($0) }
                        let errRest = self.stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let handle = { (line: String) in
                            self.capturedStderr += line + "\n"
                            self.onStderrLine?(line)
                        }
                        self.stderrSplitter.feed(errRest, onLine: handle)
                        self.stderrSplitter.flush(onLine: handle)
                        cont.resume(returning: p.terminationStatus)
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() } // SIGTERM
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
