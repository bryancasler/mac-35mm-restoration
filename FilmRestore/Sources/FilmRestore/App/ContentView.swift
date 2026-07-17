import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showOpenPanel = false

    var body: some View {
        Group {
            if let media = model.media {
                loadedView(media)
            } else {
                dropZone
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .alert("Error", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showABPlayer) { abSheet }
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

    private func loadedView(_ media: MediaInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                probeCard(media)
                GroupBox("Deflicker") { deflickerControls }
                GroupBox("Encode") { encodeControls }
                GroupBox("Test clip") { testClipControls(media) }
                actions(media)
                if let out = model.lastOutput {
                    Label {
                        Text("Done: \(out.lastPathComponent)")
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            .padding(20)
        }
        .overlay { if model.isBusy { progressOverlay } }
    }

    private func probeCard(_ m: MediaInfo) -> some View {
        GroupBox {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Source").bold()
                Spacer()
                Button("Choose another…") { showOpenPanel = true }.disabled(model.isBusy)
            }
        }
    }

    private var deflickerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable deflicker", isOn: $model.deflicker.enabled)
            HStack {
                Text("Window size: \(model.deflicker.size)")
                Slider(value: .init(get: { Double(model.deflicker.size) },
                                    set: { model.deflicker.size = Int($0.rounded()) }),
                       in: 2...129, step: 1)
            }.disabled(!model.deflicker.enabled)
            Picker("Mode", selection: $model.deflicker.mode) {
                ForEach(DeflickerSettings.Mode.allCases) { Text($0.label).tag($0) }
            }.disabled(!model.deflicker.enabled)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var encodeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Video", selection: $model.encode.codec) {
                ForEach(EncodeSettings.VideoCodec.allCases) { Text($0.label).tag($0) }
            }
            switch model.encode.codec {
            case .hevcVideoToolbox:
                HStack {
                    Text("Quality: \(model.encode.quality)")
                    Slider(value: .init(get: { Double(model.encode.quality) },
                                        set: { model.encode.quality = Int($0.rounded()) }),
                           in: 1...100, step: 1)
                }
            case .x265:
                Stepper("CRF: \(model.encode.x265CRF)", value: $model.encode.x265CRF, in: 0...51)
            case .ffv1:
                Text("Lossless — output will be very large").foregroundStyle(.orange)
            }
            Picker("Audio", selection: $model.encode.audio) {
                ForEach(EncodeSettings.AudioMode.allCases) { Text($0.label).tag($0) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func testClipControls(_ media: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Start at")
                TextField("10:00", text: $model.clipStartString).frame(width: 90)
                Text("for 60 s")
                Spacer()
                Button("Render test clip") { model.renderTestClip() }
                    .disabled(model.isBusy)
                    .keyboardShortcut("t")
            }
            if model.abClipA != nil {
                Button("Open A/B player") { model.showABPlayer = true }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ media: MediaInfo) -> some View {
        HStack {
            Spacer()
            Button {
                model.runFullRestore()
            } label: {
                Label("Restore full video", systemImage: "wand.and.stars").padding(4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
        }
    }

    // MARK: progress + A/B

    private var progressOverlay: some View {
        VStack(spacing: 12) {
            Text(model.jobLabel ?? "").font(.headline)
            if let p = model.jobProgress {
                ProgressView(value: p.fraction)
                    .frame(width: 320)
                Text(progressLine(p)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 320)
            }
            Button("Cancel") { model.cancelJob() }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25))
    }

    private func progressLine(_ p: JobProgress) -> String {
        var parts = ["frame \(p.frame)/\(p.totalFrames)"]
        if p.fps > 0 { parts.append(String(format: "%.0f fps", p.fps)) }
        if p.speed > 0 { parts.append(String(format: "%.1fx", p.speed)) }
        if let eta = p.etaSeconds { parts.append("ETA " + AppModel.format(seconds: eta)) }
        return parts.joined(separator: " · ")
    }

    private var abSheet: some View {
        VStack(spacing: 0) {
            if let a = model.abClipA, let b = model.abClipB, let m = model.media {
                ABPlayerView(clipA: a, clipB: b, fpsNum: m.fpsNum, fpsDen: m.fpsDen)
                    .frame(minWidth: 900, minHeight: 640)
            }
            HStack {
                Text("SPACE flip A/B · P pause · ⇦⇨ frame-step").foregroundStyle(.secondary)
                Spacer()
                Button("Close") { model.showABPlayer = false }.keyboardShortcut(.escape)
            }
            .padding(10)
        }
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
