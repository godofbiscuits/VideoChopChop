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
    @State private var showingImporter = false
    @State private var showingExportFolder = false
    @State private var showingInspector = true

    var body: some View {
        NavigationSplitView {
            sceneList
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .inspector(isPresented: $showingInspector) {
            InspectorView(model: model) { showingExportFolder = true }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarItem {
                Button("Open Video", systemImage: "film") { showingImporter = true }
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") { showingInspector.toggle() }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { Task { await model.open(url) } }
        }
        .fileImporter(isPresented: $showingExportFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await model.export(to: url) } }
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

    private var sceneList: some View {
        List(model.scenes) { scene in
            Button { model.seek(to: scene.startTime) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let url = model.videoURL { SceneThumbnail(url: url, time: scene.startTime) }
                    Text("Scene \(scene.index + 1)").font(.headline)
                    Text("\(scene.startTime.formatted(.number.precision(.fractionLength(2)))) s · \(scene.duration.formatted(.number.precision(.fractionLength(2)))) s · \(scene.endFrame - scene.startFrame) frames")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
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
                TimelineStrip(scenes: model.scenes, duration: model.duration, onSeek: model.seek(to:))
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
