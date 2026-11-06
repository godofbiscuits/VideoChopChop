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

    /// The file the user chose. `videoURL` is what is actually played and analyzed: the same file, or a
    /// converted MP4 when macOS can't read the original container (MKV, WebM).
    private(set) var sourceName: String?
    private(set) var isConverting = false
    private(set) var conversionProgress = 0.0

    private(set) var isAnalyzing = false
    /// Nil until the scan reports its first position (and again once it is finished).
    private(set) var analysisProgress: AnalysisProgress?
    private(set) var statusMessage: String?
    var errorMessage: String?

    // MARK: Ingest state
    private(set) var isIngesting = false
    /// Nil until the first image has been reported (and again once the ingest is finished).
    private(set) var ingestProgress: AnalysisProgress?
    /// The folder the last ingest created, and the statistics computed from the images in it.
    private(set) var ingestFolder: URL?
    private(set) var ingestStatistics: IngestStatistics?
    private(set) var isComputingStatistics = false
    /// Statistics from the detected scenes, available as soon as the scan finishes (nothing written yet).
    private(set) var sceneStatistics: IngestStatistics?
    /// A request to bring the statistics window forward; the window opener resets it to false.
    var showingStatistics = false

    var filters = FilterSettings() { didSet { if filters != oldValue { scheduleCompositionUpdate() } } }
    var sceneCutConfig = SceneCutConfig()

    // MARK: Ingest settings (chosen before an ingest, remembered between launches)
    /// Vertical resolution of the written images; 0 means keep the original size.
    var ingestHeight: Int { didSet { defaults.set(ingestHeight, forKey: Self.heightKey) } }
    /// Write every Nth frame (1 = every frame). Images are named by absolute frame number either way.
    var ingestFrameStep: Int { didSet { defaults.set(ingestFrameStep, forKey: Self.stepKey) } }
    var jxl: JXLSettings {
        didSet {
            defaults.set(jxl.lossless, forKey: Self.losslessKey)
            defaults.set(Double(jxl.distance), forKey: Self.distanceKey)
            defaults.set(jxl.effort, forKey: Self.effortKey)
        }
    }
    static let heightChoices = [240, 360, 480, 720, 1080, 0]
    private static let heightKey = "ingest.height", stepKey = "ingest.frameStep"
    private static let losslessKey = "ingest.lossless", distanceKey = "ingest.distance", effortKey = "ingest.effort"

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

    private let converter: MediaConverter
    private let defaults: UserDefaults
    private var conversionTask: Task<URL, any Error>?
    @ObservationIgnored private var ingestTask: Task<Void, Never>?
    @ObservationIgnored private var openGeneration = 0

    init(converter: MediaConverter = MediaConverter(), defaults: UserDefaults = .standard) {
        self.converter = converter
        self.defaults = defaults
        ingestHeight = defaults.object(forKey: Self.heightKey) as? Int ?? 480
        ingestFrameStep = max(defaults.object(forKey: Self.stepKey) as? Int ?? 1, 1)
        var settings = JXLSettings()
        if let lossless = defaults.object(forKey: Self.losslessKey) as? Bool { settings.lossless = lossless }
        if let distance = defaults.object(forKey: Self.distanceKey) as? Double { settings.distance = Float(distance) }
        if let effort = defaults.object(forKey: Self.effortKey) as? Int { settings.effort = effort }
        jxl = settings
        // AVPlayer's periodic observer also fires on seeks, so the playhead follows scrubbing too.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentSeconds = time.seconds }
        }
    }

    // MARK: Opening

    /// Opens a video. Containers macOS can't read (MKV, WebM) are first converted to a cached MP4,
    /// which is lossless wherever the codecs allow it.
    func open(_ chosen: URL) async {
        openGeneration += 1
        let generation = openGeneration
        analysisTask?.cancel()
        conversionTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = chosen.startAccessingSecurityScopedResource() ? chosen : nil

        thumbnailTask?.cancel()
        thumbnails = [:]
        selectedSceneIndex = nil
        scenes = []
        sceneStatistics = nil
        ingestStatistics = nil
        ingestFolder = nil
        statusMessage = nil
        errorMessage = nil
        isConverting = false
        sourceName = chosen.lastPathComponent

        let url: URL
        if await MediaConverter.avFoundationCanRead(chosen) {
            url = chosen
        } else {
            isConverting = true
            conversionProgress = 0
            statusMessage = "Converting \(chosen.lastPathComponent)…"
            let converter = converter
            // Built here, on the main actor, so the weak capture is of the real `self`, not of a task's captured copy.
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in self?.conversionProgress = fraction }
            }
            let task = Task { try await converter.prepare(chosen, progress: report) }
            conversionTask = task
            do {
                url = try await task.value
            } catch {
                guard generation == openGeneration else { return }   // superseded by another open
                isConverting = false
                statusMessage = nil
                videoURL = nil
                errorMessage = (error as? CancellationError) == nil ? error.localizedDescription : nil
                return
            }
            isConverting = false
            statusMessage = nil
        }
        guard generation == openGeneration else { return }

        videoURL = url
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
        analysisProgress = nil
        errorMessage = nil
        let config = sceneCutConfig
        analysisTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let relay = ProgressRelay { [weak self] in self?.analysisProgress = $0 }
            do {
                let found = try await SceneCutDetector().analyze(url: url, config: config, progress: relay.report)
                selectedSceneIndex = nil
                scenes = found
                sceneStatistics = IngestStatistics.make(scenes: found)
                loadThumbnails(for: found)
                statusMessage = "Found \(found.count) scene\(found.count == 1 ? "" : "s")."
            } catch is CancellationError {
                statusMessage = "Analysis cancelled."
            } catch {
                errorMessage = "Analysis failed: \(error.localizedDescription)"
            }
            await relay.finish()
            isAnalyzing = false
            analysisProgress = nil
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
            // Thumbnails are published in batches: with thousands of scenes, one UI update per thumbnail would
            // re-drive the timeline thousands of times.
            var batch: [Int: CGImage] = [:]
            var lastPublish = ContinuousClock.now
            for scene in scenes {
                if Task.isCancelled { return }
                if let result = try? await generator.image(at: CMTime(seconds: scene.startTime, preferredTimescale: 60000)) {
                    batch[scene.index] = result.image
                }
                if lastPublish.duration(to: .now) > .milliseconds(150) {
                    thumbnails.merge(batch) { $1 }
                    batch = [:]
                    lastPublish = .now
                }
            }
            thumbnails.merge(batch) { $1 }
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
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
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

    // MARK: Ingest

    var isBusy: Bool { isConverting || isAnalyzing || isIngesting }

    /// Stops whatever is running: the conversion, the scene scan, or the ingest (which removes its partial folder).
    func cancelWork() {
        conversionTask?.cancel()
        analysisTask?.cancel()
        ingestTask?.cancel()
    }

    /// Starts an ingest into a new folder inside `parent` and returns immediately; the work runs in the background.
    func beginIngest(into parent: URL) {
        guard let url = videoURL, !scenes.isEmpty, !isIngesting, !isAnalyzing else { return }
        guard let encoder = FrameEncoders.jpegXL(jxl) else {
            errorMessage = "JPEG XL needs the JXLKit package linked to the app (see Packages/JXLKit)."
            return
        }
        let granted = parent.startAccessingSecurityScopedResource()
        isIngesting = true
        ingestProgress = nil
        ingestFolder = nil
        ingestStatistics = nil
        errorMessage = nil
        statusMessage = nil

        var options = ExportOptions()
        options.targetHeight = ingestHeight > 0 ? ingestHeight : nil
        options.frameStep = max(ingestFrameStep, 1)
        options.chain = filters.chain
        let scenes = scenes
        let name = sourceName ?? url.lastPathComponent
        let movieName = (name as NSString).deletingPathExtension

        // Low priority: the user's own interaction always wins over the ingest.
        ingestTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let relay = ProgressRelay { [weak self] in self?.ingestProgress = $0 }
            do {
                let result = try await FrameExporter().export(
                    url: url, scenes: scenes, toParent: parent, movieName: movieName, options: options,
                    encoder: encoder, sourceName: name, progress: relay.report
                )
                await relay.finish()
                ingestProgress = nil
                ingestFolder = result.folder
                statusMessage = "Wrote the images to “\(result.folder.lastPathComponent)”. Computing statistics…"
                await computeStatistics(for: result.folder)
            } catch is CancellationError {
                await relay.finish()
                statusMessage = "Export cancelled; nothing was kept."
            } catch {
                await relay.finish()
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
            if granted { parent.stopAccessingSecurityScopedResource() }
            isIngesting = false
            ingestProgress = nil
        }
    }

    /// `beginIngest` that waits for the ingest (and its statistics) to finish.
    func ingest(into parent: URL) async {
        beginIngest(into: parent)
        await ingestTask?.value
    }

    /// Statistics are computed from the images on disk, in the background.
    private func computeStatistics(for folder: URL) async {
        isComputingStatistics = true
        defer { isComputingStatistics = false }
        do {
            let statistics = try await IngestFolderScanner.scanInBackground(folder: folder)
            try? IngestFolderScanner.write(statistics, to: folder)
            ingestStatistics = statistics
            showingStatistics = true
            statusMessage = "Exported \(statistics.imageCount.formatted()) images in \(statistics.sceneCount) scene folders to “\(folder.lastPathComponent)”."
        } catch {
            errorMessage = "The images were written, but the statistics failed: \(error.localizedDescription)"
        }
    }
}
