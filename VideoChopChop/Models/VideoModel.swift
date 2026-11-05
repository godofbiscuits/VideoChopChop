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

    /// The scene the player is cued to. While set, playback stops at the end of that scene
    /// (the start of the next one) via `AVPlayerItem.forwardPlaybackEndTime`.
    var selectedSceneIndex: Int? {
        didSet { if selectedSceneIndex != oldValue { selectionChanged() } }
    }

    /// First frame of each scene, keyed by scene index; filled in after analysis.
    private(set) var thumbnails: [Int: CGImage] = [:]
    /// Timeline zoom: 1 fits the whole video in the window.
    var timelineZoom = 1.0

    let player = AVPlayer()
    /// Current playback position, updated about 30 times a second (drives the timeline playhead).
    private(set) var currentSeconds = 0.0
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var isAdvancingSelection = false
    @ObservationIgnored private var endObserver: Task<Void, Never>?
    private var scopedURL: URL?
    private var compositionTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    var canExportJXL: Bool { FrameEncoders.jpegXL(jxl) != nil }

    init() {
        // AVPlayer's periodic observer also fires on seeks, so the playhead follows scrubbing too.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentSeconds = time.seconds }
        }
    }

    // MARK: Opening

    func open(_ url: URL) async {
        analysisTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil

        videoURL = url
        thumbnailTask?.cancel()
        thumbnails = [:]
        selectedSceneIndex = nil
        scenes = []
        statusMessage = nil
        errorMessage = nil
        let asset = AVURLAsset(url: url)
        duration = (try? await asset.load(.duration).seconds) ?? 0
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observePlaybackEnd(of: item)
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
                selectedSceneIndex = nil
                scenes = found
                loadThumbnails(for: found)
                statusMessage = "Found \(found.count) scene\(found.count == 1 ? "" : "s")."
            } catch is CancellationError {
                statusMessage = "Analysis cancelled."
            } catch {
                errorMessage = "Analysis failed: \(error.localizedDescription)"
            }
            isAnalyzing = false
        }
    }

    /// One shared generator produces every scene's first frame, in order, so thumbnails fill in left to right.
    private func loadThumbnails(for scenes: [SceneSegment]) {
        thumbnailTask?.cancel()
        thumbnails = [:]
        guard let url = videoURL else { return }
        thumbnailTask = Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for scene in scenes {
                if Task.isCancelled { return }
                if let result = try? await generator.image(at: CMTime(seconds: scene.startTime, preferredTimescale: 60000)) {
                    thumbnails[scene.index] = result.image
                }
            }
        }
    }

    /// Selects a scene: cues the player to its start. Choosing the current scene again re-cues it,
    /// which is how you replay a scene after it has played.
    func selectScene(_ index: Int) {
        if selectedSceneIndex == index {
            selectionChanged()
        } else {
            selectedSceneIndex = index
        }
    }

    /// Free seek (e.g. a timeline click): clears any scene selection so playback runs on normally.
    func seek(to seconds: Double) {
        selectedSceneIndex = nil
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Scene-bounded playback

    private func selectionChanged() {
        guard let index = selectedSceneIndex, scenes.indices.contains(index) else {
            player.currentItem?.forwardPlaybackEndTime = .invalid
            return
        }
        let scene = scenes[index]
        // The last scene simply plays to the end of the video.
        let isLast = index == scenes.count - 1
        player.currentItem?.forwardPlaybackEndTime = isLast ? .invalid : CMTime(seconds: scene.endTime, preferredTimescale: 60000)
        if !isAdvancingSelection {
            player.pause()
            player.seek(to: CMTime(seconds: scene.startTime, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func observePlaybackEnd(of item: AVPlayerItem) {
        endObserver?.cancel()
        endObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVPlayerItemDidPlayToEndTime, object: item) {
                self?.sceneDidFinishPlaying()
            }
        }
    }

    /// The player has paused at the end of the selected scene, which is the start of the next:
    /// cue the next scene (without seeking) so the next press of play runs it.
    private func sceneDidFinishPlaying() {
        guard let index = selectedSceneIndex, index + 1 < scenes.count else { return }
        isAdvancingSelection = true
        selectedSceneIndex = index + 1
        isAdvancingSelection = false
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
