//
//  IngestStatisticsTests.swift
//  VideoChopChopTests
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VideoChopChop

struct DistributionTests {
    @Test func computesTheBasicStatistics() {
        let distribution = Distribution([2, 4, 4, 4, 5, 5, 7, 9])
        #expect(distribution.count == 8)
        #expect(distribution.mean == 5)
        #expect(distribution.standardDeviation == 2)           // the classic population example
        #expect(distribution.median == 4.5)
        #expect(distribution.min == 2 && distribution.max == 9)
        #expect(abs(distribution.p90 - 7.6) < 1e-9)            // rank 0.9 * 7 = 6.3 → 7 + 0.3 * (9 - 7)
    }

    @Test func histogramAccountsForEveryValueWithSensibleBins() {
        let values = (1...200).map { Double($0 % 37 + ($0 % 5) * 11) }
        let distribution = Distribution(values)
        #expect(distribution.histogram.reduce(0) { $0 + $1.count } == values.count, "every value lands in exactly one bin")
        #expect((5...30).contains(distribution.histogram.count))
        // Bins are contiguous and cover min...max.
        #expect(distribution.histogram.first?.lower == distribution.min)
        #expect(abs((distribution.histogram.last?.upper ?? 0) - distribution.max) < 1e-9)
        #expect(zip(distribution.histogram, distribution.histogram.dropFirst()).allSatisfy { abs($0.upper - $1.lower) < 1e-9 })
    }

    @Test func identicalValuesFormOneBin() {
        let distribution = Distribution([30, 30, 30])
        #expect(distribution.histogram.count == 1 && distribution.histogram[0].count == 3)
        #expect(distribution.standardDeviation == 0 && distribution.median == 30)
    }

    @Test func emptyAndSingleValues() {
        #expect(Distribution([]) == .empty)
        let one = Distribution([12])
        #expect(one.mean == 12 && one.median == 12 && one.p90 == 12 && one.histogram.map(\.count) == [1])
    }
}

struct IngestStatisticsMathTests {
    @Test func averagesAndDurationsComeFromFramesAndFrameRate() {
        let statistics = IngestStatistics.make(
            framesPerScene: [30, 60, 90], frameCount: 180, imageCount: 180, frameRate: 30, frameStep: 1, totalBytes: 1_800_000, imageSizes: ["854x480"]
        )
        #expect(statistics.sceneCount == 3)
        #expect(statistics.averageFramesPerScene == 60)
        #expect(statistics.averageSecondsPerScene == 2)
        #expect(statistics.secondsPerScene.min == 1 && statistics.secondsPerScene.max == 3)
        #expect(statistics.averageBytesPerImage == 10_000)
        #expect(statistics.framesPerScene.histogram.reduce(0) { $0 + $1.count } == 3)
    }

    @Test func statisticsComeStraightFromTheScannedScenes() throws {
        let scenes = [
            SceneSegment(index: 0, startTime: 0, endTime: 1, startFrame: 0, endFrame: 30, cutScore: 0),
            SceneSegment(index: 1, startTime: 1, endTime: 3, startFrame: 30, endFrame: 90, cutScore: 0.8),
            SceneSegment(index: 2, startTime: 3, endTime: 6, startFrame: 90, endFrame: 180, cutScore: 0.7),
        ]
        let statistics = try #require(IngestStatistics.make(scenes: scenes))
        #expect(statistics.sceneCount == 3 && statistics.frameCount == 180)
        #expect(statistics.frameRate == 30)
        #expect(statistics.averageFramesPerScene == 60 && statistics.averageSecondsPerScene == 2)
        #expect(statistics.imageCount == 0 && statistics.totalBytes == 0 && statistics.imageSizes.isEmpty)
        #expect(IngestStatistics.make(scenes: []) == nil)
    }

    @Test func aZeroFrameRateDoesNotDivideByZero() {
        let statistics = IngestStatistics.make(framesPerScene: [10], frameCount: 10, imageCount: 10, frameRate: 0, frameStep: 1, totalBytes: 0, imageSizes: [])
        #expect(statistics.averageSecondsPerScene == 0)
    }
}

struct IngestFolderScannerTests {
    /// Builds an ingest folder by hand: a manifest plus numbered scene folders of numbered (empty-ish) files.
    private func makeIngest(
        scenes: [[Int]], frameCount: Int, frameRate: Double, step: Int = 1, fileExtension: String = "jxl", writeManifest: Bool = true
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, frames) in scenes.enumerated() {
            let sceneFolder = folder.appendingPathComponent(FrameExporter.zeroPadded(index + 1, width: 4))
            try FileManager.default.createDirectory(at: sceneFolder, withIntermediateDirectories: true)
            for number in frames {
                try Data(repeating: 7, count: 100).write(to: sceneFolder.appendingPathComponent("\(FrameExporter.zeroPadded(number, width: 6)).\(fileExtension)"))
            }
        }
        if writeManifest {
            let manifest = ExportManifest(
                source: "x.mkv", frameRate: frameRate, frameCount: frameCount, frameStep: step, targetHeight: 480, imageWidth: 854,
                imageHeight: 480, fileExtension: fileExtension, firstSceneNumber: 1, firstFrameNumber: 1, sceneNumberWidth: 4,
                frameNumberWidth: 6, scenes: []
            )
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("scenes.json"))
        }
        return folder
    }

    @Test func countsScenesAndFramesFromTheImagesOnDisk() throws {
        let folder = try makeIngest(scenes: [Array(1...40), Array(41...70), Array(71...100)], frameCount: 100, frameRate: 25)
        defer { try? FileManager.default.removeItem(at: folder) }

        let statistics = try IngestFolderScanner.scan(folder: folder)
        #expect(statistics.sceneCount == 3)
        #expect(statistics.imageCount == 100 && statistics.frameCount == 100)
        #expect(statistics.framesPerScene.min == 30 && statistics.framesPerScene.max == 40)
        #expect(abs(statistics.averageFramesPerScene - 100.0 / 3) < 1e-9)
        #expect(abs(statistics.averageSecondsPerScene - 100.0 / 3 / 25) < 1e-9)
        #expect(statistics.totalBytes == 100 * 100)
        #expect(statistics.frameRate == 25)
    }

    @Test func skippedFramesStillGiveExactSceneLengths() throws {
        // Every 10th frame plus each scene's first frame: images at 1, 11, 21 | 26, 31, 41, 51 | 61, 71, 81.
        let folder = try makeIngest(scenes: [[1, 11, 21], [26, 31, 41, 51], [61, 71, 81]], frameCount: 90, frameRate: 30, step: 10)
        defer { try? FileManager.default.removeItem(at: folder) }

        let statistics = try IngestFolderScanner.scan(folder: folder)
        #expect(statistics.imageCount == 10, "only the images that exist are counted as images")
        #expect(statistics.frameCount == 90)
        // Scene spans come from first-frame numbers: 26 - 1, 61 - 26, 91 - 61.
        #expect(statistics.framesPerScene.min == 25 && statistics.framesPerScene.max == 35)
        #expect(statistics.framesPerScene.mean == 30)
        #expect(statistics.averageSecondsPerScene == 1)
        #expect(statistics.frameStep == 10)
    }

    @Test func ignoresStrayFilesAndFolders() throws {
        let folder = try makeIngest(scenes: [Array(1...10), Array(11...20)], frameCount: 20, frameRate: 10)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("stats.json"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("0001/.DS_Store"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("0001/notes.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("not a scene"), withIntermediateDirectories: true)

        let statistics = try IngestFolderScanner.scan(folder: folder)
        #expect(statistics.sceneCount == 2 && statistics.imageCount == 20)
    }

    @Test func orderScenesNumerically() throws {
        // 12 scenes: "0010" must sort after "0002", not before it.
        let scenes = (0..<12).map { Array(($0 * 5 + 1)...($0 * 5 + 5)) }
        let folder = try makeIngest(scenes: scenes, frameCount: 60, frameRate: 5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let statistics = try IngestFolderScanner.scan(folder: folder)
        #expect(statistics.sceneCount == 12 && statistics.framesPerScene.min == 5 && statistics.framesPerScene.max == 5)
    }

    @Test func foldersWithoutAManifestOrScenesAreRefused() throws {
        let noManifest = try makeIngest(scenes: [[1, 2]], frameCount: 2, frameRate: 1, writeManifest: false)
        let noScenes = try makeIngest(scenes: [], frameCount: 0, frameRate: 1)
        defer {
            try? FileManager.default.removeItem(at: noManifest)
            try? FileManager.default.removeItem(at: noScenes)
        }
        #expect(throws: IngestStatisticsError.noManifest) { try IngestFolderScanner.scan(folder: noManifest) }
        #expect(throws: IngestStatisticsError.noScenes) { try IngestFolderScanner.scan(folder: noScenes) }
    }
}

@MainActor
struct IngestEndToEndTests {
    private func wait(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "ingest-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func ingestingAThreeSceneVideoGivesTheExpectedFoldersAndStatistics() async throws {
        let video = try await makeTestVideo(segments: [
            .solid(220, 30, 30, frames: 30), .solid(30, 30, 220, frames: 30), .horizontalGradient(frames: 30),
        ])
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: parent)
        }

        let model = VideoModel(defaults: freshDefaults())
        await model.open(video)
        #expect(await wait(timeout: 15) { model.scenes.count == 3 && !model.isAnalyzing }, "scenes: \(model.scenes.count)")

        // Statistics exist straight after the scan, from the scenes, before anything is exported.
        let fromVideo = try #require(model.sceneStatistics)
        #expect(fromVideo.sceneCount == 3 && fromVideo.frameCount == 90 && fromVideo.imageCount == 0)
        #expect(model.ingestStatistics == nil)

        await model.ingest(into: parent)

        #expect(model.errorMessage == nil, "\(model.errorMessage ?? "")")
        let folder = try #require(model.ingestFolder)
        #expect(folder.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["0001", "0002", "0003", "scenes.json", "stats.json"])

        let statistics = try #require(model.ingestStatistics)
        #expect(model.showingStatistics)
        #expect(statistics.sceneCount == 3)
        #expect(statistics.imageCount == 90 && statistics.frameCount == 90)
        #expect(statistics.averageFramesPerScene == 30)
        #expect(abs(statistics.averageSecondsPerScene - 1) < 0.05, "seconds \(statistics.averageSecondsPerScene)")
        #expect(statistics.imageSizes == ["320x180"], "no upscaling: \(statistics.imageSizes)")
        #expect(statistics.totalBytes > 0 && statistics.averageBytesPerImage > 0)

        // stats.json holds the same numbers.
        let saved = try JSONDecoder().decode(IngestStatistics.self, from: Data(contentsOf: folder.appendingPathComponent("stats.json")))
        #expect(saved == statistics)
        #expect(!model.isIngesting && model.ingestProgress == nil)
    }

    @Test func settingsPersistBetweenLaunches() {
        let defaults = freshDefaults()
        let first = VideoModel(defaults: defaults)
        #expect(first.ingestHeight == 480 && first.ingestFrameStep == 1)
        #expect(first.jxl == JXLSettings(lossless: false, distance: 1.5, effort: 3))

        first.ingestHeight = 720
        first.ingestFrameStep = 5
        first.jxl.distance = 2.5
        first.jxl.lossless = true

        let second = VideoModel(defaults: defaults)
        #expect(second.ingestHeight == 720 && second.ingestFrameStep == 5)
        #expect(second.jxl.distance == 2.5 && second.jxl.lossless)
    }

    @MainActor @Test func theUIStaysResponsiveWhileScanningAndIngesting() async throws {
        // Long enough that the scan and ingest take a few seconds of real work.
        let video = try await makeTestVideo(segments: [
            .solid(220, 30, 30, frames: 150), .solid(30, 30, 220, frames: 150), .horizontalGradient(frames: 150),
        ], width: 960, height: 540)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-busy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: parent)
        }

        // A heartbeat on the main actor: if anything blocks the main thread, the gap between ticks grows.
        // The longest gap is tracked per phase so a stall can be pinned on what caused it.
        // On a busy machine a one-off scheduler hiccup can exceed the bound, but app work that really blocks the main
        // thread would do it every time, so the measurement gets a second attempt before the test fails.
        var attempt = try await measureMainThreadStalls(video: video, parent: parent)
        if attempt.worst >= Self.stallBound {
            attempt = try await measureMainThreadStalls(video: video, parent: parent)
        }
        #expect(attempt.imageCount == 450)
        #expect(attempt.ticks > 50, "the heartbeat ran \(attempt.ticks) times in \(attempt.elapsed)")
        #expect(attempt.worst < Self.stallBound, "longest main-thread stall \(attempt.gaps) during \(attempt.elapsed) of scan + ingest")
    }

    /// 10 ms ticks; ~100 ms would be a visible hitch. The bound is loose because this is a loaded debug build.
    private static let stallBound = Duration.milliseconds(250)

    private struct StallMeasurement {
        var gaps: [String: Duration]
        var ticks: Int
        var elapsed: Duration
        var imageCount: Int?
        var worst: Duration { gaps.values.max() ?? .zero }
    }

    /// Opens, scans and exports `video` with a main-actor heartbeat running, and reports the longest gaps per phase.
    private func measureMainThreadStalls(video: URL, parent: URL) async throws -> StallMeasurement {
        let model = VideoModel(defaults: freshDefaults())   // (creating the app's model is launch cost, not a stall)
        // The state lives in a main-actor box so the heartbeat task and the test body share it without a race.
        let beat = HeartbeatState()
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                beat.longestGap[beat.phase] = max(beat.longestGap[beat.phase] ?? .zero, last.duration(to: now))
                beat.ticks += 1
                last = now
            }
        }

        let started = ContinuousClock.now
        await model.open(video)
        beat.phase = "scan"
        _ = await wait(timeout: 60) { model.scenes.count == 3 && !model.isAnalyzing }
        beat.phase = "ingest"
        await model.ingest(into: parent)
        let elapsed = started.duration(to: .now)
        heartbeat.cancel()
        return StallMeasurement(gaps: beat.longestGap, ticks: beat.ticks, elapsed: elapsed, imageCount: model.ingestStatistics?.imageCount)
    }
}

@MainActor
struct StatisticsWindowTests {
    /// Renders the statistics view offscreen and checks the two histograms sit side by side.
    @Test func theTwoHistogramsAreSideBySide() throws {
        let scenes = (0..<40).map { i in
            let start = i * (20 + (i * 7) % 50)
            return SceneSegment(index: i, startTime: Double(start) / 25, endTime: Double(start + 20 + (i * 7) % 50) / 25,
                                startFrame: start, endFrame: start + 20 + (i * 7) % 50, cutScore: 0.5)
        }
        let statistics = try #require(IngestStatistics.make(scenes: scenes))
        let view = IngestStatsView(statistics: statistics, source: .video, folder: nil, sourceName: "Test.mkv")
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 480)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width < 1400)

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            Attachment.record(png, named: "statistics-window.png")
        }
        // Two charts of equal width: both halves of the lower part contain accent-coloured bars.
        func hasBars(inLeftHalf left: Bool) -> Bool {
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            let xs = left ? Array(0..<width / 2) : Array(width / 2..<width)
            for y in stride(from: height / 2, to: height, by: 4) {
                for x in xs.striding(by: 4) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.blueComponent > 0.6 && c.redComponent < 0.4 { return true }
                }
            }
            return false
        }
        #expect(hasBars(inLeftHalf: true) && hasBars(inLeftHalf: false))
    }
}

private extension Array {
    func striding(by step: Int) -> [Element] { stride(from: 0, to: count, by: step).map { self[$0] } }
}

@MainActor
private final class HeartbeatState {
    var phase = "open"
    var longestGap: [String: Duration] = [:]
    var ticks = 0
}

@MainActor
struct ExportAsImagesActionTests {
    private func wait(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func emptyDefaults() -> UserDefaults {
        let suite = "export-intent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func refusesWithAClearReasonWhenItCannotRun() async throws {
        let defaults = emptyDefaults()
        let model = VideoModel(defaults: defaults)
        await #expect(throws: ExportFailure.noVideo) { try await ExportAsImagesAction.run(model: model, height: nil, frameStep: nil, defaults: defaults) }
        await #expect(throws: ExportFailure.invalidHeight) { try await ExportAsImagesAction.run(model: model, height: 0, frameStep: nil, defaults: defaults) }
        await #expect(throws: ExportFailure.invalidStep) { try await ExportAsImagesAction.run(model: model, height: nil, frameStep: 301, defaults: defaults) }

        // A scanned video but no export folder yet.
        let video = try await makeTestVideo(segments: [.solid(220, 30, 30, frames: 20), .solid(30, 30, 220, frames: 20)])
        defer { try? FileManager.default.removeItem(at: video) }
        await model.open(video)
        #expect(await wait(timeout: 15) { model.scenes.count == 2 && !model.isAnalyzing })
        await #expect(throws: ExportFailure.noFolder) { try await ExportAsImagesAction.run(model: model, height: nil, frameStep: nil, defaults: defaults) }
        #expect(ExportFailure.noFolder.message.contains("Choose an export folder"))
    }

    @Test func exportsTheOpenVideoIntoTheLastFolderWithPerRunOverrides() async throws {
        let defaults = emptyDefaults()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("export-intent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let video = try await makeTestVideo(segments: [
            .solid(220, 30, 30, frames: 30), .solid(30, 30, 220, frames: 30), .horizontalGradient(frames: 30),
        ], width: 320, height: 180)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: parent)
        }
        let model = VideoModel(defaults: defaults)
        await model.open(video)
        #expect(await wait(timeout: 15) { model.scenes.count == 3 && !model.isAnalyzing })

        // A first export (as the panel flow does) establishes the folder; the voice run then reuses it.
        await model.ingest(into: parent)
        #expect(model.exportFolder?.standardizedFileURL == parent.standardizedFileURL)

        let summary = try await ExportAsImagesAction.run(model: model, height: 90, frameStep: 10, defaults: defaults)
        // Every 10th frame plus each scene's first frame: frames 1, 11, 21 of each 30-frame scene.
        #expect(summary.contains("9 images in 3 scenes"), "\(summary)")
        #expect(model.ingestStatistics?.imageSizes == ["160x90"], "\(model.ingestStatistics?.imageSizes ?? [])")
        // The overrides applied to that run only; the saved settings are untouched.
        #expect(model.ingestHeight == 480 && model.ingestFrameStep == 1)
    }
}
