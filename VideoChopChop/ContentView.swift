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

    /// The timeline plus room for its always-visible scroll bar.
    private let timelineHeight = SceneTimelineView.totalHeight + 18

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
                    // Zoom is exponential: the slider is in powers of two around the comfortable scale.
                    Slider(
                        value: Binding(get: { log2(model.timelineZoom) }, set: { model.timelineZoom = pow(2, $0) }),
                        in: -6...6
                    )
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
    /// Always shown, so it is a drop target even before a video is loaded; it draws its own message when empty.
    private var timeline: some View {
        SceneTimeline(
            scenes: model.scenes, thumbnails: model.thumbnails, duration: model.duration,
            playhead: model.currentSeconds, selectedSceneIndex: model.selectedSceneIndex,
            zoom: model.timelineZoom, placeholder: timelinePlaceholder,
            onScrub: model.seek(to:), onSelectScene: model.selectScene(_:), onDropVideo: openDropped(_:),
            onZoomChange: { model.timelineZoom = $0 }
        )
        .frame(height: timelineHeight)
    }

    private var timelinePlaceholder: String? {
        guard model.scenes.isEmpty else { return nil }
        if model.videoURL == nil { return "Drop a video here, or choose Open Video, to find its scene cuts." }
        return model.isAnalyzing ? "Finding scene cuts…" : "No scenes found."
    }

    private func openDropped(_ url: URL) {
        Task { await model.open(url) }
    }

    private var detail: some View {
        VStack(spacing: 12) {
            PlayerView(player: model.player, onDropVideo: openDropped(_:))
                .frame(minHeight: 300)
                .overlay {
                    if model.videoURL == nil {
                        // Must not take hit-testing, or it would swallow drags meant for the player.
                        Text("Drop a video here to begin").foregroundStyle(.secondary).allowsHitTesting(false)
                    }
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
