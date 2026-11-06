//
//  FrameExporterTests.swift
//  VideoChopChopTests
//

import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoChopChop

/// Stand-in encoder so layout and numbering are tested independently of libjxl. Optionally slow or failing.
private struct FakeEncoder: FrameEncoder {
    var delay: TimeInterval = 0
    var failOnPixelWidth: Int?
    var fileExtension: String { "fake" }

    struct Failure: Error {}

    func encode(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if failOnPixelWidth == width { throw Failure() }
        return Data("\(width)x\(height)".utf8)
    }
}

private func scene(_ index: Int, frames: Range<Int>, fps: Double = 30) -> SceneSegment {
    SceneSegment(
        index: index, startTime: Double(frames.lowerBound) / fps, endTime: Double(frames.upperBound) / fps,
        startFrame: frames.lowerBound, endFrame: frames.upperBound, cutScore: index == 0 ? 0 : 0.9
    )
}

private func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func imageSize(_ url: URL) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (try #require(properties[kCGImagePropertyPixelWidth] as? Int), try #require(properties[kCGImagePropertyPixelHeight] as? Int))
}

/// A parent folder for one test's output, removed afterwards.
private final class Sandbox {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-test-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: parent) }
}

struct FrameExporterNamingTests {
    @Test func zeroPadsNumbers() {
        #expect(FrameExporter.zeroPadded(7, width: 4) == "0007")
        #expect(FrameExporter.zeroPadded(12345, width: 3) == "12345")
        #expect(FrameExporter.zeroPadded(0, width: 2) == "00")
    }

    @Test func scalesToTheTargetHeightWithoutEverUpscaling() {
        #expect(FrameRenderer.scaledSize(width: 1280, height: 720, targetHeight: 480)! == (853, 480))
        #expect(FrameRenderer.scaledSize(width: 1920, height: 1080, targetHeight: 480)! == (853, 480))
        #expect(FrameRenderer.scaledSize(width: 1280, height: 720, targetHeight: 240)! == (427, 240))
        #expect(FrameRenderer.scaledSize(width: 320, height: 180, targetHeight: 480) == nil, "smaller sources are not upscaled")
        #expect(FrameRenderer.scaledSize(width: 854, height: 480, targetHeight: 480) == nil)
        #expect(FrameRenderer.scaledSize(width: 1920, height: 1080, targetHeight: nil) == nil, "nil keeps the original size")
    }

    @Test func neverOverwritesAnExistingFolder() throws {
        let sandbox = try Sandbox()
        let first = try FrameExporter.makeUniqueDirectory(named: "Movie", in: sandbox.parent)
        try Data("precious".utf8).write(to: first.appendingPathComponent("keep.txt"))
        let second = try FrameExporter.makeUniqueDirectory(named: "Movie", in: sandbox.parent)
        let third = try FrameExporter.makeUniqueDirectory(named: "Movie", in: sandbox.parent)

        #expect([first, second, third].map(\.lastPathComponent) == ["Movie", "Movie 2", "Movie 3"])
        #expect(try String(contentsOf: first.appendingPathComponent("keep.txt"), encoding: .utf8) == "precious")
    }

    @Test func cleansUpAwkwardFolderNames() throws {
        let sandbox = try Sandbox()
        #expect(try FrameExporter.makeUniqueDirectory(named: "a/b: c", in: sandbox.parent).lastPathComponent == "a-b- c")
        #expect(try FrameExporter.makeUniqueDirectory(named: "  ", in: sandbox.parent).lastPathComponent == "Movie")
    }
}

struct FrameExporterIngestTests {
    private func makeVideo(width: Int = 320, height: Int = 180, frames: Int = 90) async throws -> URL {
        try await makeTestVideo(segments: [
            .solid(220, 30, 30, frames: frames / 3), .solid(30, 30, 220, frames: frames / 3), .horizontalGradient(frames: frames / 3),
        ], width: width, height: height)
    }

    @Test func writesOneFolderPerSceneNamedByNumberWithGlobalFrameNumbers() async throws {
        let video = try await makeVideo()
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }

        let result = try await FrameExporter().export(
            url: video, scenes: [scene(0, frames: 0..<30), scene(1, frames: 30..<60), scene(2, frames: 60..<90)],
            toParent: sandbox.parent, movieName: "My Movie", options: ExportOptions(), encoder: FakeEncoder(), sourceName: "My Movie.mkv"
        )

        #expect(result.folder.lastPathComponent == "My Movie")
        #expect(try names(in: result.folder) == ["0001", "0002", "0003", "scenes.json"])
        let expected = [("0001", 1...30), ("0002", 31...60), ("0003", 61...90)]
        for (folderName, frames) in expected {
            let files = try names(in: result.folder.appendingPathComponent(folderName))
            #expect(files == frames.map { FrameExporter.zeroPadded($0, width: 6) + ".fake" }, "scene folder \(folderName)")
        }
    }

    @Test func theManifestDescribesTheIngest() async throws {
        let video = try await makeVideo()
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }
        var options = ExportOptions()
        options.targetHeight = 480

        let result = try await FrameExporter().export(
            url: video, scenes: [scene(0, frames: 0..<45), scene(1, frames: 45..<90)],
            toParent: sandbox.parent, movieName: "M", options: options, encoder: FakeEncoder(), sourceName: "Original Name.mkv"
        )
        let decoded = try JSONDecoder().decode(ExportManifest.self, from: Data(contentsOf: result.folder.appendingPathComponent("scenes.json")))

        #expect(decoded == result.manifest)
        #expect(decoded.source == "Original Name.mkv", "the user's file name, not the cache name")
        #expect(decoded.frameCount == 90 && decoded.frameStep == 1)
        #expect(decoded.firstSceneNumber == 1 && decoded.firstFrameNumber == 1)
        #expect(decoded.sceneNumberWidth == 4 && decoded.frameNumberWidth == 6)
        #expect(decoded.scenes.count == 2)
        // 320x180 is already shorter than 480, so it is kept as is.
        #expect(decoded.imageWidth == 320 && decoded.imageHeight == 180)
        #expect(abs(decoded.frameRate - 30) < 0.5)
    }

    @Test func skippedFramesStillUseTheirAbsoluteFrameNumbers() async throws {
        let video = try await makeVideo()
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }
        var options = ExportOptions()
        options.frameStep = 10

        // Scene 2 starts at frame index 25, which is not a multiple of 10: its first frame must still be written.
        let result = try await FrameExporter().export(
            url: video, scenes: [scene(0, frames: 0..<25), scene(1, frames: 25..<60), scene(2, frames: 60..<90)],
            toParent: sandbox.parent, movieName: "Sparse", options: options, encoder: FakeEncoder()
        )

        func numbers(_ folder: String) throws -> [Int] {
            try names(in: result.folder.appendingPathComponent(folder)).compactMap { Int($0.dropLast(".fake".count)) }
        }
        #expect(try numbers("0001") == [1, 11, 21])
        #expect(try numbers("0002") == [26, 31, 41, 51], "first frame of the scene (26), then every 10th by absolute number")
        #expect(try numbers("0003") == [61, 71, 81])
        #expect(result.manifest.frameStep == 10 && result.manifest.frameCount == 90)
    }

    @Test func existingFoldersAreLeftAlone() async throws {
        let video = try await makeVideo(frames: 30)
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }
        let existing = sandbox.parent.appendingPathComponent("Movie")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing.appendingPathComponent("notes.txt"))

        let result = try await FrameExporter().export(
            url: video, scenes: [scene(0, frames: 0..<30)], toParent: sandbox.parent, movieName: "Movie",
            options: ExportOptions(), encoder: FakeEncoder()
        )

        #expect(result.folder.lastPathComponent == "Movie 2")
        #expect(try names(in: existing) == ["notes.txt"])
    }

    @Test func scalesRealImagesToTheChosenVerticalResolution() async throws {
        let encoder = try #require(FrameEncoders.jpegXL(JXLSettings()))
        let video = try await makeVideo(width: 1280, height: 720, frames: 6)
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }

        for (target, expected) in [(480, (853, 480)), (240, (427, 240)), (nil, (1280, 720))] as [(Int?, (Int, Int))] {
            var options = ExportOptions()
            options.targetHeight = target
            let result = try await FrameExporter().export(
                url: video, scenes: [scene(0, frames: 0..<6)], toParent: sandbox.parent, movieName: "Scaled \(target ?? 0)",
                options: options, encoder: encoder
            )
            let firstImage = result.folder.appendingPathComponent("0001/000001.jxl")
            let size = try imageSize(firstImage)
            #expect(size.width == expected.0 && size.height == expected.1, "target \(String(describing: target)): got \(size)")
            #expect((result.manifest.imageWidth, result.manifest.imageHeight) == expected)
            #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithURL(firstImage as CFURL, nil))) as String? == UTType.jpegxl.identifier)
        }
    }

    @Test func failureRemovesTheFolderItCreated() async throws {
        let video = try await makeVideo(frames: 30)
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }

        await #expect(throws: FakeEncoder.Failure.self) {
            _ = try await FrameExporter().export(
                url: video, scenes: [scene(0, frames: 0..<30)], toParent: sandbox.parent, movieName: "Doomed",
                options: ExportOptions(), encoder: FakeEncoder(failOnPixelWidth: 320)
            )
        }
        #expect(try names(in: sandbox.parent).isEmpty, "nothing is left behind")
    }

    @Test func cancellingRemovesThePartialFolder() async throws {
        let video = try await makeVideo(frames: 150)
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }
        let parent = sandbox.parent

        let task = Task {
            try await FrameExporter().export(
                url: video, scenes: [scene(0, frames: 0..<150)], toParent: parent, movieName: "Cancelled",
                options: ExportOptions(), encoder: FakeEncoder(delay: 0.05)
            )
        }
        // Wait until it has really started writing, then cancel.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: parent.appendingPathComponent("Cancelled/0001").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let outcome = await task.result
        #expect({ if case .failure = outcome { true } else { false } }(), "a cancelled ingest throws")
        #expect(try names(in: parent).isEmpty, "the partial folder is removed")
    }

    @Test func aMovieWithNoScenesIsRefused() async throws {
        let video = try await makeVideo(frames: 30)
        let sandbox = try Sandbox()
        defer { try? FileManager.default.removeItem(at: video) }
        await #expect(throws: ExportError.self) {
            _ = try await FrameExporter().export(
                url: video, scenes: [], toParent: sandbox.parent, movieName: "Empty", options: ExportOptions(), encoder: FakeEncoder()
            )
        }
        #expect(try names(in: sandbox.parent).isEmpty)
    }
}

struct LossyEncodingTests {
    /// Photograph-like texture: smooth shading plus fine noise (flat colours would compress to nothing either way).
    private func texturedImage(width: Int = 854, height: Int = 480) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let shade = 110 + 70 * sin(Double(x) / 37) * cos(Double(y) / 53)
                for channel in 0..<3 {
                    let noise = Double.random(in: -9...9, using: &generator)
                    let value = shade + Double(channel * 12) + noise + 25 * sin(Double(x + y * 2) / 7)
                    pixels[(y * width + x) * 4 + channel] = UInt8(min(max(value, 0), 255))
                }
            }
        }
        return pixels
    }

    private func decode(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    @Test func theDefaultsAreLossyAndMuchSmallerWithFidelityKept() throws {
        #expect(JXLSettings().lossless == false, "lossy by default")
        let lossy = try #require(FrameEncoders.jpegXL(JXLSettings()))
        let lossless = try #require(FrameEncoders.jpegXL(JXLSettings(lossless: true)))
        let source = texturedImage()

        let small = try lossy.encode(rgba: source, width: 854, height: 480)
        let big = try lossless.encode(rgba: source, width: 854, height: 480)
        #expect(small.count * 3 < big.count, "lossy \(small.count) bytes vs lossless \(big.count): should be at least 3x smaller")

        // Fidelity in OKLab: the mean colour error stays far below one just-noticeable difference (~0.02).
        let decoded = try decode(small)
        var total: Float = 0
        for i in 0..<(854 * 480) {
            let a = OKLabMath.fromSRGB8(r: source[i * 4], g: source[i * 4 + 1], b: source[i * 4 + 2])
            let b = OKLabMath.fromSRGB8(r: decoded[i * 4], g: decoded[i * 4 + 1], b: decoded[i * 4 + 2])
            total += a.distance(to: b)
        }
        let meanError = total / Float(854 * 480)
        #expect(meanError < 0.02, "mean OKLab error \(meanError)")
    }
}
