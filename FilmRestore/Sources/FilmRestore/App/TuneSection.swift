import SwiftUI

/// Workflow section 2: presets + the four filter cards, simple-by-default —
/// primary controls visible, everything else behind an Advanced disclosure.
struct TuneSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tune", systemImage: "slider.horizontal.3")
                .font(.title3.bold())
            HStack {
                Text("Preset:").foregroundStyle(.secondary)
                ForEach(Preset.all) { preset in
                    Button(preset.name) { model.apply(preset: preset) }
                        .help(preset.note)
                }
                Spacer()
            }
            deflickerCard
            scratchCard
            dirtCard
            encodeCard
        }
    }

    private var deflickerCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Deflicker", isOn: $model.deflicker.enabled)
                    .font(.body.bold())
                HStack {
                    Text("Window: \(model.deflicker.size) frames")
                    Slider(value: .init(get: { Double(model.deflicker.size) },
                                        set: { model.deflicker.size = Int($0.rounded()) }),
                           in: 2...129, step: 1)
                }
                .disabled(!model.deflicker.enabled)
                DisclosureGroup("Advanced") {
                    Picker("Mode", selection: $model.deflicker.mode) {
                        ForEach(DeflickerSettings.Mode.allCases) { Text($0.label).tag($0) }
                    }
                }
                .disabled(!model.deflicker.enabled)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scratchCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Scratch removal", isOn: $model.scratch.enabled)
                    .font(.body.bold())
                Picker("Polarity", selection: $model.scratch.polarity) {
                    ForEach(ScratchSettings.ScratchPolarity.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!model.scratch.enabled)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Stepper("Detection threshold: \(model.scratch.mindif)",
                                    value: $model.scratch.mindif, in: 1...255)
                            Stepper("Min length: \(model.scratch.minlen)px",
                                    value: $model.scratch.minlen, in: 3...1000, step: 10)
                        }
                        HStack {
                            Stepper("Max angle: \(model.scratch.maxangle, specifier: "%.0f")°",
                                    value: $model.scratch.maxangle, in: 0...15)
                            Stepper("Max width: \(model.scratch.oddMaxwidth)px",
                                    value: $model.scratch.maxwidth, in: 1...15, step: 2)
                        }
                        HStack {
                            Stepper("Asymmetry: \(model.scratch.asym)",
                                    value: $model.scratch.asym, in: 0...255, step: 5)
                            Stepper("Max gap: \(model.scratch.maxgap)px",
                                    value: $model.scratch.maxgap, in: 0...30)
                        }
                    }
                }
                .disabled(!model.scratch.enabled)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dirtCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Dirt removal", isOn: $model.dirt.enabled)
                    .font(.body.bold())
                Group {
                    Picker("Engine", selection: $model.dirt.engine) {
                        ForEach(DirtSettings.Engine.allCases) { Text($0.label).tag($0) }
                    }
                    switch model.dirt.engine {
                    case .maskClean:
                        Stepper("Sensitivity: \(44 - model.dirt.mcSensitivity)",
                                value: .init(get: { 44 - model.dirt.mcSensitivity },
                                             set: { model.dirt.mcSensitivity = 44 - $0 }),
                                in: 4...32)
                        Toggle("AI-assisted scratch detection (needs AI engine — see Setup)",
                               isOn: $model.dirt.mcUseML)
                    case .removeDirtMC, .removeDirt:
                        Stepper("Strength: \(model.dirt.strength)",
                                value: $model.dirt.strength, in: 1...30)
                    case .spotLess:
                        Stepper("Strength (thsad): \(model.dirt.thsad)",
                                value: $model.dirt.thsad, in: 1000...30000, step: 1000)
                    }
                    DisclosureGroup("Advanced") {
                        VStack(alignment: .leading, spacing: 6) {
                            switch model.dirt.engine {
                            case .maskClean:
                                Stepper("Max spot size: \(model.dirt.mcMaxSize)px",
                                        value: $model.dirt.mcMaxSize, in: 100...2000, step: 100)
                                Picker("Detect", selection: $model.dirt.mcPolarity) {
                                    ForEach(DirtSettings.Polarity.allCases) { Text($0.label).tag($0) }
                                }
                                Toggle("Protect dark line art from AI repair (animation)",
                                       isOn: $model.dirt.mcProtectDark)
                                    .disabled(!model.dirt.mcUseML)
                            case .removeDirtMC:
                                Text("Motion-compensated cleaning — keeps working during camera moves.")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .removeDirt:
                                Stepper("Scene threshold: \(model.dirt.gmthreshold)%",
                                        value: $model.dirt.gmthreshold, in: 0...100, step: 5)
                                Text("Legacy engine — stops cleaning wherever the camera moves.")
                                    .font(.caption).foregroundStyle(.orange)
                            case .spotLess:
                                Stepper("Temporal radius: \(model.dirt.radT)",
                                        value: $model.dirt.radT, in: 1...3)
                                Toggle("True-motion vectors (worse on fast motion)",
                                       isOn: $model.dirt.spotTrueMotion)
                            }
                        }
                    }
                }
                .disabled(!model.dirt.enabled)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var encodeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Encode").font(.body.bold())
                HStack {
                    Text("Quality: \(model.encode.quality)")
                    Slider(value: .init(get: { Double(model.encode.quality) },
                                        set: { model.encode.quality = Int($0.rounded()) }),
                           in: 1...100, step: 1)
                }
                .disabled(model.encode.codec != .hevcVideoToolbox)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Video", selection: $model.encode.codec) {
                            ForEach(EncodeSettings.VideoCodec.allCases) { Text($0.label).tag($0) }
                        }
                        if model.encode.codec == .x265 {
                            Stepper("CRF: \(model.encode.x265CRF)",
                                    value: $model.encode.x265CRF, in: 0...51)
                        }
                        if model.encode.codec == .ffv1 {
                            Text("Lossless — output will be very large").foregroundStyle(.orange)
                        }
                        Picker("Audio", selection: $model.encode.audio) {
                            ForEach(EncodeSettings.AudioMode.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
