//
//  SceneCutDetectorTests.swift
//  VideoChopChopTests
//

import CoreVideo
import Foundation
import Testing
@testable import VideoChopChop

struct SceneCutDetectorTests {
    @Test func deciderHonorsFloorAndMinimumLength() {
        var decider = CutDecider(config: SceneCutConfig())
        let quiet = decider.isCut(score: 0.1, time: 0)
        let firstCut = decider.isCut(score: 0.9, time: 1.0)
        // Too soon after the previous cut, even though the score is high.
        let tooSoon = decider.isCut(score: 0.9, time: 1.2)
        // Quiet frames keep the rolling median low, so a later spike counts as a cut again.
        for i in 0..<30 { _ = decider.isCut(score: 0.05, time: 1.3 + Double(i) / 30) }
        let secondCut = decider.isCut(score: 0.9, time: 2.5)
        #expect(!quiet)
        #expect(firstCut)
        #expect(!tooSoon)
        #expect(secondCut)
    }

    @Test func deciderAdaptsToBusyFootage() {
        var decider = CutDecider(config: SceneCutConfig())
        // Continuous high motion raises the rolling median, so equally high scores stop counting as cuts.
        var cuts = 0
        for i in 0..<60 where decider.isCut(score: 0.5, time: Double(i) / 30) { cuts += 1 }
        #expect(cuts <= 2)
    }

    @Test func findsHardCutsInSyntheticVideo() async throws {
        let url = try await makeTestVideo(segments: [
            .solid(220, 30, 30, frames: 30),
            .solid(30, 30, 220, frames: 30),
            .horizontalGradient(frames: 30),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var config = SceneCutConfig()
        config.confirmWithVision = false
        let scenes = try await SceneCutDetector().analyze(url: url, config: config)

        #expect(scenes.count == 3)
        let starts = scenes.map(\.startFrame)
        #expect(starts.count == 3 && abs(starts[1] - 30) <= 1 && abs(starts[2] - 60) <= 1)
        #expect(scenes.first?.startFrame == 0)
        #expect(scenes.last?.endFrame == 90)
    }

    @Test func gradualFadeIsNotACut() async throws {
        // Starts at 10% gray: OKLab lightness is steepest right next to pure black, so a fade that
        // begins at exactly black can legitimately register a large first-step change.
        let url = try await makeTestVideo(segments: [.grayRamp(from: 0.1, to: 0.95, frames: 90)])
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SceneCutConfig()
        config.confirmWithVision = false
        let scenes = try await SceneCutDetector().analyze(url: url, config: config)
        #expect(scenes.count == 1)
    }

    @Test func visionConfirmationKeepsRealCuts() async throws {
        let url = try await makeTestVideo(segments: [
            .horizontalGradient(frames: 30),
            .solid(30, 200, 30, frames: 30),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let scenes = try await SceneCutDetector().analyze(url: url)
        #expect(scenes.count == 2)
    }
}

struct FrameDownscalerTests {
    private func solidBuffer(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true]
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height { for x in 0..<width {
            let p = base + y * stride + x * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        } }
        return pixelBuffer
    }

    @Test func downscalesInLinearLightOnTheGPU() async throws {
        let downscaler = try #require(FrameDownscaler(width: 64, height: 36))
        // sRGB 128 is 0.2158 in linear light (not 0.502): the shrink must run on decoded values.
        let frame = try solidBuffer(width: 1920, height: 1080, b: 128, g: 128, r: 128)
        let values = try #require(await downscaler.linearRGBA(of: frame))
        #expect(values.count == 64 * 36 * 4)
        for i in stride(from: 0, to: values.count, by: 4 * 97) {
            #expect(abs(values[i] - 0.2158) < 0.005 && abs(values[i + 1] - 0.2158) < 0.005 && abs(values[i + 2] - 0.2158) < 0.005)
        }
    }

    @Test func aBlackAndWhiteFrameKeepsItsHalvesApart() async throws {
        let downscaler = try #require(FrameDownscaler(width: 64, height: 36))
        let frame = try solidBuffer(width: 640, height: 360, b: 255, g: 255, r: 255)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<360 { for x in 0..<320 { let p = base + y * stride + x * 4; p[0] = 0; p[1] = 0; p[2] = 0 } }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let values = try #require(await downscaler.linearRGBA(of: frame))
        let leftmost = values[0], rightmost = values[(63) * 4]
        #expect(leftmost < 0.05 && rightmost > 0.95, "left \(leftmost) right \(rightmost)")
    }
}
