//
//  ContentView.swift
//  VideoChopChop
//
//  Created by Jeffrey Barbose on 11/5/26.
//

import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = VideoModel()
    @State private var showingInspector = true

    var body: some View {
        NavigationSplitView {
            sceneList
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
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

    private var sceneList: some View {
        // Selecting a scene cues the player to its start; pressing play then plays just that scene.
        List(model.scenes, selection: $model.selectedSceneIndex) { scene in
            VStack(alignment: .leading, spacing: 4) {
                if let url = model.videoURL { SceneThumbnail(url: url, time: scene.startTime) }
                Text("Scene \(scene.index + 1)").font(.headline)
                Text("\(scene.startTime.formatted(.number.precision(.fractionLength(2)))) s · \(scene.duration.formatted(.number.precision(.fractionLength(2)))) s · \(scene.endFrame - scene.startFrame) frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.scenes.isEmpty {
                ContentUnavailableView(
                    model.videoURL == nil ? "No video" : "No scenes yet",
                    systemImage: "film",
                    description: Text(model.videoURL == nil ? "Open a video to find its scene cuts." : "Analysis hasn't finished.")
                )
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 12) {
            PlayerView(player: model.player)
                .frame(minHeight: 300)
                .overlay {
                    if model.videoURL == nil { Text("Open a video to begin").foregroundStyle(.secondary) }
                }
            if !model.scenes.isEmpty {
                SceneTimeline(
                    scenes: model.scenes, duration: model.duration, playhead: model.currentSeconds,
                    selectedSceneIndex: model.selectedSceneIndex, onScrub: model.seek(to:)
                )
                .frame(height: 32)
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
