import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showOpenPanel = false
    @State private var showQueuePanel = false
    @State private var showSetup = false

    var body: some View {
        Group {
            if let media = model.media {
                loadedView(media)
            } else {
                dropZone
            }
        }
        .frame(minWidth: 560, minHeight: 480)
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
                HStack {
                    Text("Preset:")
                    ForEach(Preset.all) { preset in
                        Button(preset.name) { model.apply(preset: preset) }
                            .help(preset.note)
                    }
                    Spacer()
                }
                GroupBox("Deflicker") { deflickerControls }
                GroupBox("Scratch removal (DeScratch)") { scratchControls }
                GroupBox("Dirt removal") { dirtControls }
                GroupBox("Encode") { encodeControls }
                GroupBox("Test clip") { testClipControls(media) }
                GroupBox("Side-by-side comparison") { sideBySideControls }
                GroupBox("Queue") { queueControls }
                actions(media)
                if let stats = model.lastStats, !model.isBusy {
                    Label(stats, systemImage: "chart.bar")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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

    private var scratchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Remove vertical scratches", isOn: $model.scratch.enabled)
            Group {
                HStack {
                    Stepper("Detection threshold (mindif): \(model.scratch.mindif)",
                            value: $model.scratch.mindif, in: 1...255)
                    Stepper("Min length: \(model.scratch.minlen)",
                            value: $model.scratch.minlen, in: 3...1000, step: 10)
                }
                HStack {
                    Stepper("Max angle: \(model.scratch.maxangle, specifier: "%.0f")°",
                            value: $model.scratch.maxangle, in: 0...15)
                    Stepper("Max width: \(model.scratch.oddMaxwidth)",
                            value: $model.scratch.maxwidth, in: 1...15, step: 2)
                }
                Toggle("Mark detected scratches (preview only, doesn't fix)",
                       isOn: $model.scratch.markOnly)
            }.disabled(!model.scratch.enabled)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dirtControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Remove dust & dirt", isOn: $model.dirt.enabled)
            Group {
                Picker("Engine", selection: $model.dirt.engine) {
                    ForEach(DirtSettings.Engine.allCases) { Text($0.label).tag($0) }
                }
                switch model.dirt.engine {
                case .removeDirtMC:
                    Stepper("Strength: \(model.dirt.strength)",
                            value: $model.dirt.strength, in: 1...30)
                    Text("Motion-compensated — keeps cleaning during camera moves. Strength 6–10 typical, up to 25–30 for badly damaged film.")
                        .font(.caption).foregroundStyle(.secondary)
                case .removeDirt:
                    HStack {
                        Stepper("Strength: \(model.dirt.strength)",
                                value: $model.dirt.strength, in: 1...30)
                        Stepper("Scene threshold: \(model.dirt.gmthreshold)%",
                                value: $model.dirt.gmthreshold, in: 0...100, step: 5)
                    }
                    Text("Legacy engine: stops cleaning wherever the camera moves — kept for comparison.")
                        .font(.caption).foregroundStyle(.orange)
                case .spotLess:
                    HStack {
                        Stepper("Strength (thsad): \(model.dirt.thsad)",
                                value: $model.dirt.thsad, in: 1000...30000, step: 1000)
                        Stepper("Temporal radius: \(model.dirt.radT)",
                                value: $model.dirt.radT, in: 1...3)
                    }
                    Toggle("True-motion vectors (worse on fast motion)", isOn: $model.dirt.spotTrueMotion)
                    Text("~3x realtime (vs ~14x for RemoveDirt)").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!model.dirt.enabled)
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
                HStack {
                    Button("Open A/B player") { model.showABPlayer = true }
                    Button("Pin B as A") { model.pinBAsA() }
                        .help("Keep the current filtered clip as the A side, then change settings and re-render to compare two variants")
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sideBySideControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Renders source (left) and restored (right) into one video.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Start at")
                TextField("10:00", text: $model.sbsStartString).frame(width: 90)
                Text("for")
                TextField("60", text: $model.sbsLengthString).frame(width: 50)
                Text("s")
                Button("Render side-by-side") { model.renderSideBySide(quick: false) }
                    .disabled(model.isBusy)
            }
            HStack {
                Button("Quick sample (6 × 10 s random → 1 min reel)") {
                    model.renderSideBySide(quick: true)
                }.disabled(model.isBusy)
            }
            Toggle("Add difference column (highlights what changed — black = identical)",
                   isOn: $model.sbsDiffColumn)
                .disabled(model.isBusy)
            if let out = model.sbsOutput {
                HStack {
                    Label(out.lastPathComponent, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Open") { NSWorkspace.shared.open(out) }
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var queueControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Add files…") { showQueuePanel = true }
                    .disabled(model.isBusy)
                if !model.queue.isEmpty {
                    Button("Run queue (\(model.queue.count))") { model.runQueue() }
                        .disabled(model.isBusy)
                }
            }
            ForEach(model.queue, id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button { model.queue.removeAll { $0 == url } } label: {
                        Image(systemName: "xmark.circle")
                    }.buttonStyle(.plain)
                }.font(.caption)
            }
            ForEach(model.queueResults, id: \.self) { Text($0).font(.caption) }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $showQueuePanel,
                      allowedContentTypes: [.movie, .mpeg4Movie, .item],
                      allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { model.enqueue(urls: urls) }
        }
    }

    private func actions(_ media: MediaInfo) -> some View {
        HStack {
            Picker("Processing", selection: $model.passes) {
                Text("1×").tag(1)
                Text("2× double").tag(2)
                Text("3× triple").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .help("Run the whole restoration chain this many times in a single encode (no generational loss). Applies to full runs, test clips, and side-by-side.")
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
