//
//  FrameExporter.swift
//  VideoChopChop
//
//  The ingest writer. Reads a video once and produces
//
//      <parent>/<movie name>/scenes.json
//      <parent>/<movie name>/0001/0000001.jxl, 0000002.jxl, …     (scene folder = scene number)
//      <parent>/<movie name>/0002/0000241.jxl, …                  (image name = absolute frame number)
//
//  Scene and frame numbers are 1-based and zero-padded. Frame numbers are global: they keep counting
//  across scenes and are the frame's absolute position in the movie even when frames are skipped.
//  Every image is filtered, scaled to the chosen vertical resolution and encoded off the main thread.
//

import CoreImage
import Foundation

nonisolated struct ExportOptions: Sendable, Equatable {
    /// Vertical resolution of the written images (aspect preserved). Never upscales. Nil keeps the original size.
    var targetHeight: Int? = 480
    /// Write every Nth frame (1 = every frame). A scene's first frame is always written, so every scene has images.
    /// Images are named by absolute frame number either way.
    var frameStep = 1
    var chain = FilterChain()
    /// Frames rendered and encoded in parallel.
    var maxConcurrentEncodes = max(2, min(ProcessInfo.processInfo.activeProcessorCount - 1, 8))
}

nonisolated struct ExportManifest: Codable, Sendable, Equatable {
    let source: String
    let frameRate: Double
    /// Frames in the whole movie (not just the ones written).
    let frameCount: Int
    let frameStep: Int
    let targetHeight: Int?
    /// Actual size of the written images.
    let imageWidth: Int
    let imageHeight: Int
    let fileExtension: String
    /// Folders and files are numbered from these, zero-padded to these widths.
    let firstSceneNumber: Int
    let firstFrameNumber: Int
    let sceneNumberWidth: Int
    let frameNumberWidth: Int
    /// `index` here is 0-based; the folder is `index + 1`.
    let scenes: [SceneSegment]
}

nonisolated enum ExportError: LocalizedError {
    case renderFailed(frame: Int)
    case noScenes

    var errorDescription: String? {
        switch self {
        case .renderFailed(let frame): "Could not render frame \(frame + 1)."
        case .noScenes: "There are no scenes to export yet."
        }
    }
}

/// Filters, scales and renders a frame to sRGB RGBA8. Safe to call from many tasks at once.
nonisolated final class FrameRenderer: @unchecked Sendable {
    private let context = CIContext()
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func render(
        _ frame: VideoFrame, chain: FilterChain, transform: CGAffineTransform, targetHeight: Int?
    ) throws -> (bytes: [UInt8], width: Int, height: Int) {
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        image = chain.apply(to: image)

        var width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { throw ExportError.renderFailed(frame: frame.index) }
        if let (w, h) = Self.scaledSize(width: width, height: height, targetHeight: targetHeight) {
            let scale = Double(h) / Double(height)
            // Lanczos for quality; the edge is extended so the last row/column isn't blended with transparency.
            image = image
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
                .clampedToExtent()
            (width, height) = (w, h)
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: sRGB
        )
        return (bytes, width, height)
    }

    /// The size after scaling to `targetHeight`, or nil when no scaling applies (no target, or the source is already
    /// that small: images are never upscaled).
    static func scaledSize(width: Int, height: Int, targetHeight: Int?) -> (width: Int, height: Int)? {
        guard let targetHeight, targetHeight > 0, targetHeight < height else { return nil }
        let scaledWidth = max(Int((Double(width) * Double(targetHeight) / Double(height)).rounded()), 1)
        return (scaledWidth, targetHeight)
    }
}

actor FrameExporter {
    struct Result: Sendable {
        let folder: URL
        let manifest: ExportManifest
    }

    private let renderer = FrameRenderer()

    /// Ingests `url` into a new folder named `movieName` inside `parent` and returns where it went.
    /// If anything fails or the task is cancelled, the folder this call created is removed again.
    @discardableResult
    func export(
        url: URL,
        scenes: [SceneSegment],
        toParent parent: URL,
        movieName: String,
        options: ExportOptions,
        encoder: any FrameEncoder,
        /// Name recorded in the manifest; defaults to the file's own name. (For a converted MKV this is the original.)
        sourceName: String? = nil,
        progress: (@Sendable (AnalysisProgress) -> Void)? = nil
    ) async throws -> Result {
        guard let lastScene = scenes.last else { throw ExportError.noScenes }
        let frameCount = lastScene.endFrame
        let sceneWidth = max(4, String(scenes.count).count)
        let frameWidth = max(6, String(frameCount).count)
        let step = max(options.frameStep, 1)

        let source = try await FrameSource.open(url: url)
        let folder = try Self.makeUniqueDirectory(named: movieName, in: parent)
        do {
            let imageSize = try await writeFrames(
                from: source, scenes: scenes, into: folder, step: step, sceneWidth: sceneWidth, frameWidth: frameWidth,
                frameCount: frameCount, options: options, encoder: encoder, progress: progress
            )
            let manifest = ExportManifest(
                source: sourceName ?? url.lastPathComponent, frameRate: source.frameRate, frameCount: frameCount,
                frameStep: step, targetHeight: options.targetHeight, imageWidth: imageSize.width, imageHeight: imageSize.height,
                fileExtension: encoder.fileExtension, firstSceneNumber: 1, firstFrameNumber: 1,
                sceneNumberWidth: sceneWidth, frameNumberWidth: frameWidth, scenes: scenes
            )
            let json = JSONEncoder()
            json.outputFormatting = [.prettyPrinted, .sortedKeys]
            try json.encode(manifest).write(to: folder.appendingPathComponent("scenes.json"), options: .atomic)
            progress?(AnalysisProgress(frame: frameCount, totalFrames: frameCount, seconds: source.duration, duration: source.duration))
            return Result(folder: folder, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func writeFrames(
        from source: FrameSource, scenes: [SceneSegment], into folder: URL, step: Int, sceneWidth: Int, frameWidth: Int,
        frameCount: Int, options: ExportOptions, encoder: any FrameEncoder, progress: (@Sendable (AnalysisProgress) -> Void)?
    ) async throws -> (width: Int, height: Int) {
        let fileManager = FileManager.default
        let renderer = renderer
        let transform = source.preferredTransform
        let duration = source.duration
        var imageSize = (width: 0, height: 0)
        var currentScene = 0
        var createdSceneFolder: Int?
        var sceneFolder = folder

        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            var inFlight = 0
            while let frame = try await source.next() {
                try Task.checkCancellation()
                if frame.index % 6 == 0 {
                    progress?(AnalysisProgress(frame: frame.index + 1, totalFrames: frameCount, seconds: frame.seconds, duration: duration))
                }
                // Frames arrive in order, so the scene only ever moves forward.
                while currentScene < scenes.count - 1, frame.index >= scenes[currentScene].endFrame { currentScene += 1 }
                let scene = scenes[currentScene]
                guard frame.index == scene.startFrame || frame.index % step == 0 else { continue }

                if createdSceneFolder != currentScene {
                    sceneFolder = folder.appendingPathComponent(Self.zeroPadded(scene.index + 1, width: sceneWidth), isDirectory: true)
                    try fileManager.createDirectory(at: sceneFolder, withIntermediateDirectories: true)
                    createdSceneFolder = currentScene
                }
                let fileURL = sceneFolder
                    .appendingPathComponent(Self.zeroPadded(frame.index + 1, width: frameWidth))
                    .appendingPathExtension(encoder.fileExtension)

                if inFlight >= options.maxConcurrentEncodes, let size = try await group.next() {
                    inFlight -= 1
                    if imageSize.width == 0 { imageSize = size }
                }
                let chain = options.chain, targetHeight = options.targetHeight
                group.addTask {
                    let image = try renderer.render(frame, chain: chain, transform: transform, targetHeight: targetHeight)
                    try encoder.encode(rgba: image.bytes, width: image.width, height: image.height).write(to: fileURL, options: .atomic)
                    return (image.width, image.height)
                }
                inFlight += 1
            }
            for try await size in group where imageSize.width == 0 { imageSize = size }
        }
        return imageSize
    }

    // MARK: Naming

    /// `7` → `"0007"`.
    static func zeroPadded(_ number: Int, width: Int) -> String {
        let digits = String(max(number, 0))
        return String(repeating: "0", count: max(width - digits.count, 0)) + digits
    }

    /// Creates `<parent>/<name>`, or `<name> 2`, `<name> 3`, … if that already exists. Never touches existing folders.
    static func makeUniqueDirectory(named name: String, in parent: URL) throws -> URL {
        let fileManager = FileManager.default
        let clean = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        let base = clean.isEmpty ? "Movie" : clean
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }
}
