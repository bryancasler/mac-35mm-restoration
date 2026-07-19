import SwiftUI
import UniformTypeIdentifiers

/// Workflow section 4: commit — passes, the restore button, batch queue,
/// completion stats.
struct RestoreSection: View {
    @EnvironmentObject var model: AppModel
    @State private var showQueuePanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Restore", systemImage: "wand.and.stars")
                .font(.title3.bold())
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Passes").foregroundStyle(.secondary)
                        Picker("", selection: $model.passes) {
                            Text("1×").tag(1)
                            Text("2× double").tag(2)
                            Text("3× triple").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        .help("Run the whole restoration chain this many times in a single encode (no generational loss)")
                        Spacer()
                        Button {
                            model.runFullRestore()
                        } label: {
                            Label("Restore full video", systemImage: "wand.and.stars").padding(4)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r")
                        .disabled(model.isBusy)
                    }

                    DisclosureGroup("Batch queue") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("Add files…") { showQueuePanel = true }
                                if !model.queue.isEmpty {
                                    Button("Run queue (\(model.queue.count))") { model.runQueue() }
                                }
                            }
                            .disabled(model.isBusy)
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
                    }

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
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fileImporter(isPresented: $showQueuePanel,
                      allowedContentTypes: [.movie, .mpeg4Movie, .item],
                      allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { model.enqueue(urls: urls) }
        }
    }
}
