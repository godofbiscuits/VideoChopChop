//
//  ContentView.swift
//  VideoChopChop
//
//  Created by Jeffrey Barbose on 11/5/26.
//

import SwiftUI

struct ContentView: View {
    let model: VideoModel
    @State private var showingInspector = true
    @Environment(\.openWindow) private var openWindow

    /// The timeline plus room for its always-visible scroll bar.
    private let timelineHeight = SceneTimelineView.totalHeight + 18

    var body: some View {
        VStack(spacing: 0) {
            timeline
            Divider()
            detail
        }
        .inspector(isPresented: $showingInspector) {
            InspectorView(model: model) { ingestIntoChosenFolder() }
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
        // Statistics live in their own non-modal window; the model only raises a request to show it.
        .onChange(of: model.showingStatistics) { _, requested in
            guard requested else { return }
            openWindow(id: StatisticsWindow.windowID)
            model.showingStatistics = false
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

    private func ingestIntoChosenFolder() {
        guard let url = FilePanels.chooseIngestFolder() else { return }
        model.beginIngest(into: url)
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
        if model.isConverting { return "Converting \(model.sourceName ?? "video")…" }
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

    private var statusBar: some View {
        HStack(alignment: .bottom) {
            progressContent.frame(maxWidth: .infinity, alignment: .leading)
            if model.isBusy {
                Button("Cancel") { model.cancelWork() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private var progressContent: some View {
        if model.isConverting {
            // Containers macOS can't read (MKV, WebM) are converted first; this is usually a lossless rewrap.
            ProgressView("Converting \(model.sourceName ?? "video") for playback…", value: model.conversionProgress)
        } else if model.isAnalyzing {
            if let progress = model.analysisProgress {
                ScanProgressView(progress: progress)
            } else {
                ProgressView("Finding scene cuts…")   // until the first frame has been read
            }
        } else if model.isIngesting {
            if let progress = model.ingestProgress {
                ScanProgressView(title: "Writing images…", progress: progress)
            } else {
                ProgressView("Writing images…")   // until the first frame has been written
            }
        } else if model.isComputingStatistics {
            ProgressView("Computing statistics from the images…")
        } else if let status = model.statusMessage {
            Text(status).font(.callout).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView(model: VideoModel())
}
