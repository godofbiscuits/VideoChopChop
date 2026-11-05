//
//  FrameExporterTests.swift
//  VideoChopChopTests
//

import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoChopChop

/// Stand-in encoder so exporter behavior is tested independently of libjxl.
private struct FakeEncoder: FrameEncoder {
    var fileExtension: String { "fake" }
    func encode(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        Data("\(width)x\(height):\(rgba[0]),\(rgba[1]),\(rgba[2])".utf8)
    }
}

struct FrameExporterTests {
    private let scenes = [
        SceneSegment(index: 0, startTime: 0, endTime: 1, startFrame: 0, endFrame: 30, cutScore: 0),
        SceneSegment(index: 1, startTime: 1, endTime: 2, startFrame: 30, endFrame: 60, cutScore: 0.9),
    ]

    @Test func wantedFramesEveryNth() {
        let wanted = FrameExporter.wantedFrames(scenes: scenes, selection: .every(10))
        #expect(wanted.keys.sorted() == [0, 10, 20, 30, 40, 50])
        #expect(wanted[20] == 0 && wanted[30] == 1)
    }

    @Test func wantedFramesRepresentative() {
        let wanted = FrameExporter.wantedFrames(scenes: scenes, selection: .representative)
        #expect(wanted.keys.sorted() == [0, 14, 29, 30, 44, 59])
    }

    @Test func exportsFilesAndManifest() async throws {
        let video = try await makeTestVideo(segments: [.solid(220, 30, 30, frames: 12), .solid(30, 30, 220, frames: 12)])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: output)
        }
        var config = SceneCutConfig()
        config.confirmWithVision = false
        let found = try await SceneCutDetector().analyze(url: video, config: config)
        #expect(found.count == 2)

        let manifest = try await FrameExporter().export(
            url: video, scenes: found, to: output,
            options: ExportOptions(selection: .representative), encoder: FakeEncoder()
        )

        #expect(manifest.frames.count == 6)
        for frame in manifest.frames {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(frame.file).path))
        }
        let first = try String(contentsOf: output.appendingPathComponent("scene_001/frame_000000.fake"), encoding: .utf8)
        #expect(first.hasPrefix("320x180:"))
        // The first scene is red, so the first pixel's red channel should dominate.
        let rgb = first.dropFirst("320x180:".count).split(separator: ",").compactMap { Int($0) }
        #expect(rgb.count == 3 && rgb[0] > 150 && rgb[2] < 100)

        let json = try Data(contentsOf: output.appendingPathComponent("scenes.json"))
        let decoded = try JSONDecoder().decode(ExportManifest.self, from: json)
        #expect(decoded == manifest)
    }

    @Test func exportsRealJPEGXLFiles() async throws {
        let encoder = try #require(FrameEncoders.jpegXL(JXLSettings()), "JXLKit must be linked to the app target")
        let video = try await makeTestVideo(segments: [.solid(220, 30, 30, frames: 6)])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: output)
        }
        let scene = SceneSegment(index: 0, startTime: 0, endTime: 0.2, startFrame: 0, endFrame: 6, cutScore: 0)
        try await FrameExporter().export(
            url: video, scenes: [scene], to: output, options: ExportOptions(selection: .every(6)), encoder: encoder
        )

        let file = output.appendingPathComponent("scene_001/frame_000000.jxl")
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpegxl.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 180)

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(pixel[0] > 150 && pixel[2] < 100)
    }

    @Test func filterChainIsAppliedToExportedFrames() async throws {
        let video = try await makeTestVideo(segments: [.solid(220, 30, 30, frames: 6)])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: output)
        }
        let scene = SceneSegment(index: 0, startTime: 0, endTime: 0.2, startFrame: 0, endFrame: 6, cutScore: 0)
        var options = ExportOptions(selection: .every(6))
        options.chain = FilterChain(steps: [.oklabTweak(saturation: 0, lightness: 1)])
        try await FrameExporter().export(url: video, scenes: [scene], to: output, options: options, encoder: FakeEncoder())

        let text = try String(contentsOf: output.appendingPathComponent("scene_001/frame_000000.fake"), encoding: .utf8)
        let rgb = text.dropFirst("320x180:".count).split(separator: ",").compactMap { Int($0) }
        #expect(rgb.count == 3 && abs(rgb[0] - rgb[1]) <= 3 && abs(rgb[1] - rgb[2]) <= 3)
    }
}
