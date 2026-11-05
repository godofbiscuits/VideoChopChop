//
//  FrameExporter.swift
//  VideoChopChop
//
//  Reads a video once, applies the filter chain, and writes
//  <output>/scene_001/frame_000123.<ext> plus scenes.json.
//

import CoreImage
import Foundation

nonisolated struct ExportOptions: Sendable, Equatable {
    enum FrameSelection: Sendable, Equatable {
        /// Every Nth frame (1 = all frames).
        case every(Int)
        /// First, middle and last frame of each scene.
        case representative
    }

    var selection: FrameSelection = .every(1)
    var chain = FilterChain()
    /// Frames encoded in parallel.
    var maxConcurrentEncodes = 4
}

nonisolated struct ExportManifest: Codable, Sendable, Equatable {
    struct Frame: Codable, Sendable, Equatable {
        let index: Int
        let scene: Int
        let time: Double
        let file: String
    }

    let source: String
    let frameRate: Double
    let fileExtension: String
    let scenes: [SceneSegment]
    let frames: [Frame]
}

nonisolated enum ExportError: Error {
    case renderFailed(frame: Int)
}

actor FrameExporter {
    private let context = CIContext()
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Exports frames and returns the manifest that was written to `scenes.json`.
    @discardableResult
    func export(
        url: URL,
        scenes: [SceneSegment],
        to directory: URL,
        options: ExportOptions,
        encoder: any FrameEncoder,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExportManifest {
        let wanted = Self.wantedFrames(scenes: scenes, selection: options.selection)
        let totalWanted = max(wanted.count, 1)
        let source = try await FrameSource.open(url: url)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var frames: [ExportManifest.Frame] = []
        var written = 0

        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            while let frame = try await source.next() {
                try Task.checkCancellation()
                guard let sceneIndex = wanted[frame.index] else { continue }

                let sceneDirectory = directory.appendingPathComponent(String(format: "scene_%03d", sceneIndex + 1))
                try fileManager.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)
                let fileName = String(format: "frame_%06d.%@", frame.index, encoder.fileExtension)
                let fileURL = sceneDirectory.appendingPathComponent(fileName)

                let (rgba, width, height) = try render(frame, chain: options.chain, transform: source.preferredTransform)
                if inFlight >= options.maxConcurrentEncodes {
                    try await group.next()
                    inFlight -= 1
                }
                group.addTask {
                    try encoder.encode(rgba: rgba, width: width, height: height).write(to: fileURL, options: .atomic)
                }
                inFlight += 1

                frames.append(.init(
                    index: frame.index, scene: sceneIndex, time: frame.seconds,
                    file: "\(sceneDirectory.lastPathComponent)/\(fileName)"
                ))
                written += 1
                progress?(Double(written) / Double(totalWanted))
            }
            try await group.waitForAll()
        }

        let manifest = ExportManifest(
            source: url.lastPathComponent, frameRate: source.frameRate, fileExtension: encoder.fileExtension,
            scenes: scenes, frames: frames
        )
        let encoderJSON = JSONEncoder()
        encoderJSON.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoderJSON.encode(manifest).write(to: directory.appendingPathComponent("scenes.json"), options: .atomic)
        progress?(1)
        return manifest
    }

    /// Maps frame index → scene index for every frame that should be exported.
    static func wantedFrames(scenes: [SceneSegment], selection: ExportOptions.FrameSelection) -> [Int: Int] {
        var wanted: [Int: Int] = [:]
        for scene in scenes where scene.endFrame > scene.startFrame {
            switch selection {
            case .every(let step):
                for frame in stride(from: scene.startFrame, to: scene.endFrame, by: max(step, 1)) { wanted[frame] = scene.index }
            case .representative:
                for frame in [scene.startFrame, (scene.startFrame + scene.endFrame - 1) / 2, scene.endFrame - 1] {
                    wanted[frame] = scene.index
                }
            }
        }
        return wanted
    }

    /// Applies orientation and the filter chain, then renders sRGB RGBA8 pixels.
    private func render(_ frame: VideoFrame, chain: FilterChain, transform: CGAffineTransform) throws -> ([UInt8], Int, Int) {
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        image = chain.apply(to: image)

        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { throw ExportError.renderFailed(frame: frame.index) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: sRGB
        )
        return (bytes, width, height)
    }
}
