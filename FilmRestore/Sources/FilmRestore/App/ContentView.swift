import SwiftUI
import UniformTypeIdentifiers

/// Main window: Source → Tune → Preview → Restore, with a bottom status bar
/// during jobs (UI/UX revision 2026-07-18 — sections in TuneSection /
/// PreviewSection / RestoreSection).
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showOpenPanel = false
    @State private var showSetup = false

    var body: some View {
        Group {
            if model.media != nil {
                loadedView
            } else {
                dropZone
            }
        }
        .frame(minWidth: 700, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showSetup = true } label: {
                    Label("Setup", systemImage: "stethoscope")
                }.help("Dependencies & plugin setup")
            }
        }
        .sheet(isPresented: $showSetup) {
            VStack(spacing: 0) {
                SetupView()
                HStack { Spacer(); Button("Close") { showSetup = false }.keyboardShortcut(.escape) }
                    .padding(10)
            }
        }
        .alert("Error", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("Copy debug info") {
                model.copyDebugReport()
                model.errorMessage = nil
            }
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text((model.errorMessage ?? "")
                 + "\n\n“Copy debug info” puts the error, all settings, and the job log tail on the clipboard — paste it into the Claude session to troubleshoot.")
        }
        .onChange(of: model.showABPlayer) { _, wants in
            if wants {
                openWindow(id: "abplayer")
                model.showABPlayer = false
            }
        }
        .fileImporter(isPresented: $showOpenPanel, allowedContentTypes: [.movie, .mpeg4Movie, .item]) {
            if case .success(let url) = $0 { model.load(url: url) }
        }
    }

    // MARK: empty state

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Drop a film scan here").font(.title2)
            Button("Open…") { showOpenPanel = true }
            if model.isProbing { ProgressView() }
            if !model.toolsOK {
                Label("ffmpeg not found — brew install ffmpeg", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.load(url: url) } }
            }
            return true
        }
    }

    // MARK: loaded state

    private var loadedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let media = model.media {
                    sourceSection(media)
                }
                TuneSection()
                PreviewSection()
                RestoreSection()
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if model.isBusy { statusBar }
        }
    }

    private func sourceSection(_ m: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Source", systemImage: "film")
                .font(.title3.bold())
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                        GridRow { Text("File").foregroundStyle(.secondary); Text(m.url.lastPathComponent).lineLimit(1) }
                        GridRow { Text("Video").foregroundStyle(.secondary)
                                  Text("\(m.width)×\(m.height) · \(m.fpsDisplay) fps · \(m.videoCodec) (\(m.pixFmt))") }
                        GridRow { Text("Duration").foregroundStyle(.secondary)
                                  Text("\(AppModel.format(seconds: m.durationSeconds)) · \(m.totalFrames) frames · \(bytes(m.sizeBytes))") }
                        GridRow { Text("Audio").foregroundStyle(.secondary)
                                  Text(m.audioTracks.isEmpty ? "none"
                                       : m.audioTracks.map { "\($0.codec) \($0.channels)ch \($0.sampleRate)Hz" }.joined(separator: ", ")) }
                        GridRow { Text("Estimate").foregroundStyle(.secondary)
                                  Text("output ~\(bytes(estimatedOut(m))) · run ~\(AppModel.format(seconds: m.estimatedFullRunSeconds))") }
                    }
                    if model.settingsRestoredFromSidecar {
                        Label("Settings restored from this film's last session",
                              systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack {
                    Spacer()
                    Button("Choose another…") { showOpenPanel = true }.disabled(model.isBusy)
                }
            }
        }
    }

    // MARK: status bar (replaces the blocking overlay)

    private var statusBar: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.jobProgress?.fraction ?? 0)
                .frame(width: 220)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.jobLabel ?? "").font(.callout)
                if let p = model.jobProgress {
                    Text(progressLine(p)).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel") { model.cancelJob() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func progressLine(_ p: JobProgress) -> String {
        var parts = ["frame \(p.frame)/\(p.totalFrames)"]
        if p.fps > 0 { parts.append(String(format: "%.0f fps", p.fps)) }
        if p.speed > 0 { parts.append(String(format: "%.1fx", p.speed)) }
        if let eta = p.etaSeconds { parts.append("ETA " + AppModel.format(seconds: eta)) }
        return parts.joined(separator: " · ")
    }

    private func estimatedOut(_ m: MediaInfo) -> Int64 {
        if let bps = model.testClipBytesPerSecond, model.encode.codec == .hevcVideoToolbox {
            return Int64(bps * m.durationSeconds)
        }
        return m.estimatedOutputBytes(quality: model.encode.quality)
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// The A/B player as a real, resizable window — settings stay reachable while
/// it plays (was a modal sheet).
struct ABPlayerWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let a = model.abClipA, let b = model.abClipB, let m = model.media {
                VStack(spacing: 0) {
                    ABPlayerView(clipA: a, clipB: b, fpsNum: m.fpsNum, fpsDen: m.fpsDen,
                                 clipStartFrame: model.lastClipStartFrame,
                                 videoWidth: m.width, videoHeight: m.height,
                                 onCopyReport: { marks in
                                     Task { @MainActor in model.copyDefectReport(marks: marks) }
                                 })
                    Text("SPACE flip · P pause · ⇦⇨ step · paused click = mark defect · U undo · C copy report")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(6)
                }
            } else {
                Text("Render an A/B clip first (Preview section)")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .frame(minWidth: 900, minHeight: 660)
    }
}
