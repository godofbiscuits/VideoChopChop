//
//  InspectorView.swift
//  VideoChopChop
//

import SwiftUI

struct InspectorView: View {
    @Bindable var model: VideoModel
    let onExport: () -> Void

    var body: some View {
        Form {
            Section("Scene detection") {
                LabeledContent("Sensitivity") {
                    Slider(value: $model.sceneCutConfig.absoluteFloor, in: 0.1...1.0)
                }
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

            Section("Export (JPEG XL)") {
                Toggle("One frame set per scene (first / middle / last)", isOn: $model.representativeOnly)
                if !model.representativeOnly {
                    Stepper("Every \(model.exportEveryNth) frame\(model.exportEveryNth == 1 ? "" : "s")",
                            value: $model.exportEveryNth, in: 1...300)
                }
                Toggle("Lossless", isOn: $model.jxl.lossless)
                if !model.jxl.lossless {
                    slider("Distance", Binding(get: { Double(model.jxl.distance) }, set: { model.jxl.distance = Float($0) }), 0.1...5)
                }
                Stepper("Effort \(model.jxl.effort)", value: $model.jxl.effort, in: 1...9)
                Button("Export…", action: onExport)
                    .disabled(model.scenes.isEmpty || model.isExporting)
                if !model.canExportJXL {
                    Text("JPEG XL export needs the JXLKit package added to the app target.")
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
