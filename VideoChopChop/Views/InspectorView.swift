//
//  InspectorView.swift
//  VideoChopChop
//

import SwiftUI

struct InspectorView: View {
    @Bindable var model: VideoModel
    let onIngest: () -> Void

    var body: some View {
        Form {
            Section("Scene detection") {
                LabeledContent("Cut threshold") {
                    Slider(value: $model.sceneCutConfig.absoluteFloor, in: 0.1...1.0)
                }
                Text("A frame counts as a new scene when it differs from the one before by more than this. Lower finds more cuts; higher finds fewer. Press Re-analyze to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Confirm with Vision", isOn: $model.sceneCutConfig.confirmWithVision)
                Button("Re-analyze", action: model.analyze)
                    .disabled(model.videoURL == nil || model.isAnalyzing)
            }

            Section("Core Image") {
                filterToggle("Color controls", isOn: $model.filters.colorEnabled) {
                    slider("Saturation", $model.filters.saturation, 0...2)
                    slider("Brightness", $model.filters.brightness, -0.5...0.5)
                    slider("Contrast", $model.filters.contrast, 0.5...1.5)
                }
                filterToggle("Gaussian blur", isOn: $model.filters.blurEnabled) {
                    slider("Radius", $model.filters.blurRadius, 0...30)
                }
                filterToggle("Posterize", isOn: $model.filters.posterizeEnabled) {
                    slider("Levels", $model.filters.posterizeLevels, 2...30)
                }
                filterToggle("Edges", isOn: $model.filters.edgesEnabled) {
                    slider("Intensity", $model.filters.edgeIntensity, 0...10)
                }
            }

            Section("Custom Metal kernel") {
                filterToggle("OKLab saturation / lightness", isOn: $model.filters.oklabEnabled) {
                    slider("Saturation", $model.filters.oklabSaturation, 0...2)
                    slider("Lightness", $model.filters.oklabLightness, 0.2...1.8)
                }
            }

            Section("Metal Performance Shaders") {
                filterToggle("Gaussian blur", isOn: $model.filters.mpsBlurEnabled) {
                    slider("Sigma", $model.filters.mpsSigma, 0.5...20)
                }
                Toggle("Sobel edges", isOn: $model.filters.mpsSobelEnabled)
            }

            Section("Export as Images (JPEG XL)") {
                // The settings are fixed while an ingest runs; the Cancel button below stays usable.
                Group {
                    Picker("Vertical resolution", selection: $model.ingestHeight) {
                        ForEach(VideoModel.heightChoices, id: \.self) { height in
                            Text(height == 0 ? "Original size" : "\(height) px").tag(height)
                        }
                    }
                    Stepper("Every \(model.ingestFrameStep) frame\(model.ingestFrameStep == 1 ? "" : "s")",
                            value: $model.ingestFrameStep, in: 1...300)
                    Toggle("Lossless", isOn: $model.jxl.lossless)
                    if !model.jxl.lossless {
                        // Distance 1.0 is "visually lossless"; the default 1.5 is ~7.6x smaller than lossless
                        // with a mean colour error far below visible (measured on real frames).
                        slider("Distance", Binding(get: { Double(model.jxl.distance) }, set: { model.jxl.distance = Float($0) }), 0.1...5)
                        Text("Distance \(model.jxl.distance.formatted(.number.precision(.fractionLength(1)))): lower is closer to the original, higher is smaller.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Stepper("Effort \(model.jxl.effort)", value: $model.jxl.effort, in: 1...9)
                }
                .disabled(model.isIngesting)
                Text("Images are named by absolute frame number, one folder per scene.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isIngesting {
                    Button("Cancel Export", role: .cancel, action: model.cancelWork)
                } else {
                    Button("Export as Images…", action: onIngest)
                        .disabled(model.scenes.isEmpty || model.isAnalyzing || model.isComputingStatistics)
                }
                if model.sceneStatistics != nil || model.ingestStatistics != nil {
                    Button("Show Statistics") { model.showingStatistics = true }
                }
                if !model.canExportJXL {
                    Text("JPEG XL needs the JXLKit package added to the app target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) { Slider(value: value, in: range) }
    }

    private func filterToggle<Content: View>(
        _ title: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            Toggle(title, isOn: isOn)
            if isOn.wrappedValue { content() }
        }
    }
}
