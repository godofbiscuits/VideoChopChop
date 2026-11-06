//
//  IngestStatistics.swift
//  VideoChopChop
//
//  Statistics about an ingest, computed from the images that were written to disk (their folders and
//  file names), not from the video. A scene's frame span is the gap between its first image's frame number
//  and the next scene's first image, so it stays exact even when frames were skipped (every scene's first
//  frame is always written).
//

import Foundation
import ImageIO

nonisolated struct HistogramBin: Codable, Sendable, Equatable, Identifiable {
    let lower: Double
    let upper: Double
    let count: Int
    var id: Double { lower }
    var midpoint: Double { (lower + upper) / 2 }
}

nonisolated struct Distribution: Codable, Sendable, Equatable {
    let count: Int
    let mean: Double
    let median: Double
    let p90: Double
    let min: Double
    let max: Double
    let standardDeviation: Double
    let histogram: [HistogramBin]

    static let empty = Distribution(count: 0, mean: 0, median: 0, p90: 0, min: 0, max: 0, standardDeviation: 0, histogram: [])

    init(count: Int, mean: Double, median: Double, p90: Double, min: Double, max: Double, standardDeviation: Double, histogram: [HistogramBin]) {
        self.count = count; self.mean = mean; self.median = median; self.p90 = p90
        self.min = min; self.max = max; self.standardDeviation = standardDeviation; self.histogram = histogram
    }

    init(_ values: [Double]) {
        guard !values.isEmpty else { self = .empty; return }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        self.init(
            count: values.count, mean: mean,
            median: Self.percentile(0.5, of: sorted), p90: Self.percentile(0.9, of: sorted),
            min: sorted[0], max: sorted[sorted.count - 1], standardDeviation: variance.squareRoot(),
            histogram: Self.histogram(of: sorted)
        )
    }

    /// Linear interpolation between closest ranks; `sorted` must be ascending and non-empty.
    static func percentile(_ p: Double, of sorted: [Double]) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Freedman–Diaconis bin width (2·IQR / n^⅓), clamped to between 5 and 30 bins. All values equal → one bin.
    static func histogram(of sorted: [Double]) -> [HistogramBin] {
        guard let low = sorted.first, let high = sorted.last else { return [] }
        guard high > low else { return [HistogramBin(lower: low, upper: low + 1, count: sorted.count)] }
        let iqr = percentile(0.75, of: sorted) - percentile(0.25, of: sorted)
        let width = 2 * iqr / Foundation.pow(Double(sorted.count), 1.0 / 3.0)
        let binCount = width > 0 ? Int(((high - low) / width).rounded(.up)) : 10
        let bins = Swift.min(Swift.max(binCount, 5), 30)
        let step = (high - low) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for value in sorted { counts[Swift.min(Int((value - low) / step), bins - 1)] += 1 }
        return (0..<bins).map { HistogramBin(lower: low + Double($0) * step, upper: low + Double($0 + 1) * step, count: counts[$0]) }
    }
}

nonisolated struct IngestStatistics: Codable, Sendable, Equatable {
    let sceneCount: Int
    /// Frames in the whole movie.
    let frameCount: Int
    /// Images actually on disk (fewer than `frameCount` when frames were skipped).
    let imageCount: Int
    let frameRate: Double
    let frameStep: Int
    let framesPerScene: Distribution
    let secondsPerScene: Distribution
    let totalBytes: Int
    let averageBytesPerImage: Double
    /// Distinct image sizes ("854x480") among each scene's first image, read from the file headers.
    let imageSizes: [String]

    var averageFramesPerScene: Double { framesPerScene.mean }
    var averageSecondsPerScene: Double { secondsPerScene.mean }

    /// Statistics straight from the scan's scenes, before any image exists (no image or file-size figures).
    /// The frame rate is derived from the last scene's end (its frame count over its end time).
    static func make(scenes: [SceneSegment]) -> IngestStatistics? {
        guard let last = scenes.last else { return nil }
        let frameRate = last.endTime > 0 ? Double(last.endFrame) / last.endTime : 0
        return make(
            framesPerScene: scenes.map { $0.endFrame - $0.startFrame }, frameCount: last.endFrame, imageCount: 0,
            frameRate: frameRate, frameStep: 1, totalBytes: 0, imageSizes: []
        )
    }

    /// Pure statistics from per-scene frame spans.
    static func make(
        framesPerScene: [Int], frameCount: Int, imageCount: Int, frameRate: Double, frameStep: Int, totalBytes: Int, imageSizes: [String]
    ) -> IngestStatistics {
        let frames = framesPerScene.map(Double.init)
        let seconds = frameRate > 0 ? frames.map { $0 / frameRate } : frames.map { _ in 0 }
        return IngestStatistics(
            sceneCount: framesPerScene.count, frameCount: frameCount, imageCount: imageCount, frameRate: frameRate, frameStep: frameStep,
            framesPerScene: Distribution(frames), secondsPerScene: Distribution(seconds),
            totalBytes: totalBytes, averageBytesPerImage: imageCount > 0 ? Double(totalBytes) / Double(imageCount) : 0,
            imageSizes: imageSizes
        )
    }
}

nonisolated enum IngestStatisticsError: LocalizedError {
    case noManifest
    case noScenes

    var errorDescription: String? {
        switch self {
        case .noManifest: "This folder has no scenes.json, so it isn't an ingest."
        case .noScenes: "No scene folders with images were found."
        }
    }
}

nonisolated enum IngestFolderScanner {
    static let statisticsFileName = "stats.json"

    /// Reads an ingest folder and computes its statistics. Synchronous file I/O: call it from a background task.
    static func scan(folder: URL) throws -> IngestStatistics {
        let fileManager = FileManager.default
        guard let manifestData = try? Data(contentsOf: folder.appendingPathComponent("scenes.json")),
              let manifest = try? JSONDecoder().decode(ExportManifest.self, from: manifestData)
        else { throw IngestStatisticsError.noManifest }

        // Scene folders are the all-numeric subfolders, in scene-number order.
        let sceneFolders = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            .compactMap { url -> (number: Int, url: URL)? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let number = Int(url.lastPathComponent) else { return nil }
                return (number, url)
            }
            .sorted { $0.number < $1.number }

        var firstFrames: [Int] = []
        var imageCount = 0, totalBytes = 0
        var sizes = Set<String>()
        for scene in sceneFolders {
            let images = try fileManager.contentsOfDirectory(at: scene.url, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.pathExtension == manifest.fileExtension }
                .compactMap { url -> (frame: Int, url: URL, bytes: Int)? in
                    guard let frame = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
                    return (frame, url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            guard let first = images.min(by: { $0.frame < $1.frame }) else { continue }
            firstFrames.append(first.frame)
            imageCount += images.count
            totalBytes += images.reduce(0) { $0 + $1.bytes }
            if let size = imageSize(of: first.url) { sizes.insert(size) }
        }
        guard !firstFrames.isEmpty else { throw IngestStatisticsError.noScenes }

        // A scene runs from its first image's frame number to the next scene's first (the last, to the end of the movie).
        let ends = firstFrames.dropFirst() + [manifest.frameCount + manifest.firstFrameNumber]
        let spans = zip(firstFrames, ends).map { $1 - $0 }
        return IngestStatistics.make(
            framesPerScene: spans, frameCount: manifest.frameCount, imageCount: imageCount, frameRate: manifest.frameRate,
            frameStep: manifest.frameStep, totalBytes: totalBytes, imageSizes: sizes.sorted()
        )
    }

    /// Scans on a background thread at low priority so the UI stays free.
    static func scanInBackground(folder: URL) async throws -> IngestStatistics {
        try await Task.detached(priority: .utility) { try scan(folder: folder) }.value
    }

    static func write(_ statistics: IngestStatistics, to folder: URL) throws {
        let json = JSONEncoder()
        json.outputFormatting = [.prettyPrinted, .sortedKeys]
        try json.encode(statistics).write(to: folder.appendingPathComponent(statisticsFileName), options: .atomic)
    }

    /// Pixel size from the image header (no decoding).
    private static func imageSize(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width)x\(height)"
    }
}
