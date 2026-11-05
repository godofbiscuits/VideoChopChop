//
//  ContentView.swift
//  VideoChopChop
//
//  Created by Jeffrey Barbose on 11/5/26.
//

import SwiftUI

struct ContentView: View {
    @State private var model = VideoModel()
    @State private var showingInspector = true

    private let timelineHeight = SceneTimelineView.totalHeight + 12

    var body: some View {
        VStack(spacing: 0) {
            timeline
            Divider()
            detail
        }
        .inspector(isPresented: $showingInspector) {
            InspectorView(model: model) { exportToChosenFolder() }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarItem {
                Button("Open Video", systemImage: "film") { openVideo() }
            }
            ToolbarItem {
                HStack(spacing: 4) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $model.timelineZoom, in: 1...40)
                        .frame(width: 120)
                        .accessibilityLabel("Timeline zoom")
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") { showingInspector.toggle() }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private func openVideo() {
        guard let url = FilePanels.chooseVideo() else { return }
        Task { await model.open(url) }
    }

    private func exportToChosenFolder() {
        guard let url = FilePanels.chooseExportFolder() else { return }
        Task { await model.export(to: url) }
    }

    /// Final Cut style timeline across the top: scene markers with thumbnails centered between them.
    @ViewBuilder
    private var timeline: some View {
        if model.scenes.isEmpty {
            Text(model.videoURL == nil ? "Open a video to find its scene cuts."
                 : model.isAnalyzing ? "Finding scene cuts…" : "No scenes found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: timelineHeight)
                .background(.quaternary.opacity(0.4))
        } else {
            SceneTimeline(
                scenes: model.scenes, thumbnails: model.thumbnails, duration: model.duration,
                playhead: model.currentSeconds, selectedSceneIndex: model.selectedSceneIndex,
                zoom: model.timelineZoom, onScrub: model.seek(to:), onSelectScene: model.selectScene(_:)
            )
            .frame(height: timelineHeight)
        }
    }

    private var detail: some View {
        VStack(spacing: 12) {
            PlayerView(player: model.player)
                .frame(minHeight: 300)
                .overlay {
                    if model.videoURL == nil { Text("Open a video to begin").foregroundStyle(.secondary) }
                }
            statusBar
        }
        .padding()
    }

    @ViewBuilder
    private var statusBar: some View {
        if model.isAnalyzing {
            ProgressView("Finding scene cuts…", value: model.analysisProgress)
        } else if model.isExporting {
            ProgressView("Exporting frames…", value: model.exportProgress)
        } else if let status = model.statusMessage {
            Text(status).font(.callout).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
