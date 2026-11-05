//
//  VideoModel.swift
//  VideoChopChop
//

import AVFoundation
import Observation

@MainActor
@Observable
final class VideoModel {
    private(set) var videoURL: URL?
    private(set) var scenes: [SceneSegment] = []
    private(set) var duration = 0.0

    private(set) var isAnalyzing = false
    private(set) var analysisProgress = 0.0
    private(set) var isExporting = false
    private(set) var exportProgress = 0.0
    private(set) var statusMessage: String?
    var errorMessage: String?

    var filters = FilterSettings() { didSet { if filters != oldValue { scheduleCompositionUpdate() } } }
    var sceneCutConfig = SceneCutConfig()
    var exportEveryNth = 1
    var representativeOnly = false
    var jxl = JXLSettings()

    let player = AVPlayer()
    private var scopedURL: URL?
    private var compositionTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    var canExportJXL: Bool { FrameEncoders.jpegXL(jxl) != nil }

    // MARK: Opening

    func open(_ url: URL) async {
        analysisTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil

        videoURL = url
        scenes = []
        statusMessage = nil
        errorMessage = nil
        let asset = AVURLAsset(url: url)
        duration = (try? await asset.load(.duration).seconds) ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        scheduleCompositionUpdate()
        analyze()
    }

    // MARK: Analysis

    func analyze() {
        guard let url = videoURL, !isAnalyzing else { return }
        isAnalyzing = true
        analysisProgress = 0
        errorMessage = nil
        let config = sceneCutConfig
        analysisTask = Task {
            do {
                let found = try await SceneCutDetector().analyze(url: url, config: config) { fraction in
                    Task { @MainActor in self.analysisProgress = fraction }
                }
                scenes = found
                statusMessage = "Found \(found.count) scene\(found.count == 1 ? "" : "s")."
            } catch is CancellationError {
                statusMessage = "Analysis cancelled."
            } catch {
                errorMessage = "Analysis failed: \(error.localizedDescription)"
            }
            isAnalyzing = false
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Preview filtering

    private func scheduleCompositionUpdate() {
        compositionTask?.cancel()
        guard let item = player.currentItem else { return }
        let chain = filters.chain
        compositionTask = Task {
            if chain.isEmpty {
                item.videoComposition = nil
                return
            }
            do {
                let composition = try await PreviewComposition.make(asset: item.asset, chain: chain)
                if !Task.isCancelled { item.videoComposition = composition }
            } catch {
                errorMessage = "Preview filter failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Export

    func export(to directory: URL) async {
        guard let url = videoURL, !scenes.isEmpty, !isExporting else { return }
        guard let encoder = FrameEncoders.jpegXL(jxl) else {
            errorMessage = "JPEG XL export needs the JXLKit package linked to the app (see Packages/JXLKit)."
            return
        }
        let granted = directory.startAccessingSecurityScopedResource()
        defer { if granted { directory.stopAccessingSecurityScopedResource() } }

        isExporting = true
        exportProgress = 0
        errorMessage = nil
        var options = ExportOptions(selection: representativeOnly ? .representative : .every(max(exportEveryNth, 1)))
        options.chain = filters.chain
        do {
            let manifest = try await FrameExporter().export(
                url: url, scenes: scenes, to: directory, options: options, encoder: encoder
            ) { fraction in
                Task { @MainActor in self.exportProgress = fraction }
            }
            statusMessage = "Exported \(manifest.frames.count) frames to \(directory.lastPathComponent)."
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
        isExporting = false
    }
}
