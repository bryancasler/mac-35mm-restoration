import SwiftUI

/// Workflow section 3: everything that renders a look-before-you-commit
/// artifact — A/B test clips, side-by-side reels, and the detection overlays
/// (which apply to preview renders only; full restores strip them).
struct PreviewSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Preview", systemImage: "eye")
                .font(.title3.bold())
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Start at")
                        TextField("10:00", text: $model.clipStartString).frame(width: 90)
                        Text("· A/B clips run 60 s · custom reel:")
                        TextField("60", text: $model.sbsLengthString).frame(width: 50)
                        Text("s")
                        Spacer()
                    }
                    HStack {
                        Button("Render A/B clip") { model.renderTestClip() }
                            .keyboardShortcut("t")
                        Button("Quick sample reel (6 × 10 s)") { model.renderSideBySide(quick: true) }
                        Button("Custom side-by-side") { model.renderSideBySide(quick: false) }
                    }
                    .disabled(model.isBusy)
                    HStack(spacing: 16) {
                        Toggle("Difference column", isOn: $model.sbsDiffColumn)
                        Toggle("Mark scratches", isOn: $model.scratch.markOnly)
                            .help("Preview renders highlight what DeScratch detects instead of fixing it")
                        Toggle("Show dirt mask", isOn: $model.dirt.mcShowMask)
                            .help("Preview renders overlay MaskClean detections in red (AI regions yellow)")
                    }
                    .disabled(model.isBusy)
                    Text("Overlays apply to previews only — full restores always render clean.")
                        .font(.caption).foregroundStyle(.secondary)

                    if model.abClipA != nil || model.sbsOutput != nil {
                        Divider()
                        HStack {
                            if model.abClipA != nil {
                                Button("Open A/B player") { model.showABPlayer = true }
                                Button("Pin B as A") { model.pinBAsA() }
                                    .help("Keep the current filtered clip as the A side, change settings, re-render to compare variants")
                            }
                            if let reel = model.sbsOutput {
                                Button("Open reel") { NSWorkspace.shared.open(reel) }
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([reel]) }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
