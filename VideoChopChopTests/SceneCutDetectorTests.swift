//
//  SceneCutDetectorTests.swift
//  VideoChopChopTests
//

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
