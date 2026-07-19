import SwiftUI

/// M3 guided setup: detection checklist, copy-paste brew commands with live
/// re-check, user-approved plugin provisioning, DeScratch build, doctor pane.
struct SetupView: View {
    @State private var status = DependencyDetector.detect()
    @State private var showApproval = false
    @State private var working: String?
    @State private var doctorResult: Doctor.Result?
    @State private var errorMessage: String?

    private let provisioner = PluginProvisioner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Dependencies").font(.title2).bold()

                GroupBox("Homebrew tools") {
                    VStack(alignment: .leading, spacing: 6) {
                        row("ffmpeg", status.ffmpeg)
                        row("VapourSynth", status.vapoursynth)
                        row("bestsource", status.bestsource)
                        row("meson + ninja (for DeScratch)", status.mesonNinja)
                        HStack {
                            Spacer()
                            Button("Re-check") { recheck() }
                        }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Restoration plugins (app-managed)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Installed to `~/Library/Application Support/FilmRestore/plugins` — Homebrew's tree is never touched.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(PluginSpec.all) { spec in
                            check(spec.id + " — " + spec.note,
                                  status.plugins[spec.dylib] == true)
                        }
                        check("DeScratch 4.0 — vertical scratch removal (built from source)",
                              status.descratch)
                        check("MVTools — motion estimation (built from source; prebuilt v24 is broken on VS R77)",
                              status.mvtools)
                        HStack {
                            if !status.pluginsOK {
                                Button("Download plugins…") { showApproval = true }
                                    .disabled(working != nil)
                            }
                            if !status.descratch {
                                Button("Build DeScratch") { buildDescratch() }
                                    .disabled(working != nil || isMissing(status.mesonNinja))
                            }
                            if !status.mvtools {
                                Button("Build MVTools") { buildMVTools() }
                                    .disabled(working != nil || isMissing(status.mesonNinja))
                            }
                            if let working { ProgressView().controlSize(.small); Text(working) }
                        }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Doctor") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Renders 10 frames through every plugin via vspipe.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Run smoke test") { runDoctor() }
                                .disabled(working != nil || !statusReadyForDoctor)
                            if let r = doctorResult {
                                Label(r.detail, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(r.ok ? .green : .red)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 520)
        .sheet(isPresented: $showApproval) { approvalSheet }
    }

    private var statusReadyForDoctor: Bool {
        if case .ok = status.vapoursynth { return status.pluginsOK && status.sourceBuiltOK }
        return false
    }

    private func isMissing(_ s: DependencyStatus.State) -> Bool {
        if case .missing = s { return true }
        return false
    }

    // MARK: rows

    private func row(_ name: String, _ state: DependencyStatus.State) -> some View {
        HStack {
            switch state {
            case .ok(let detail):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(name)
                Text(detail).foregroundStyle(.secondary).lineLimit(1)
            case .missing(let remedy):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(name)
                Text(remedy).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(remedy, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help("Copy command")
            }
        }
    }

    private func check(_ name: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(name)
        }
    }

    // MARK: approval + actions

    /// ADR-6: each download listed with URL + sha256; nothing fetched until approved.
    private var approvalSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve plugin downloads").font(.headline)
            Text("FilmRestore will download these exact files and verify each against its pinned SHA-256 before installing:")
            ForEach(PluginSpec.all) { spec in
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.id).bold()
                    Text(spec.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text("sha256 \(spec.sha256)").font(.caption2.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showApproval = false }
                Button("Download & install") {
                    showApproval = false
                    provisionPrebuilts()
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func provisionPrebuilts() {
        errorMessage = nil
        provisioner.onStatus = { msg in Task { @MainActor in working = msg } }
        Task {
            do { try await provisioner.provisionPrebuilts() }
            catch { errorMessage = error.localizedDescription }
            working = nil
            recheck()
        }
    }

    private func buildMVTools() {
        errorMessage = nil
        provisioner.onStatus = { msg in Task { @MainActor in working = msg } }
        Task {
            do { try await provisioner.buildMVTools() }
            catch { errorMessage = error.localizedDescription }
            working = nil
            recheck()
        }
    }

    private func buildDescratch() {
        errorMessage = nil
        provisioner.onStatus = { msg in Task { @MainActor in working = msg } }
        Task {
            do { try await provisioner.buildDeScratch() }
            catch { errorMessage = error.localizedDescription }
            working = nil
            recheck()
        }
    }

    private func runDoctor() {
        working = "Running doctor…"
        Task {
            let r = await Task.detached { Doctor.run() }.value
            doctorResult = r
            working = nil
        }
    }

    private func recheck() {
        status = DependencyDetector.detect()
    }
}
