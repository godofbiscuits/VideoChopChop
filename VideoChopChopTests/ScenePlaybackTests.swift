//
//  ScenePlaybackTests.swift
//  VideoChopChopTests
//

import AVFoundation
import Foundation
import Testing
@testable import VideoChopChop

@MainActor
struct ScenePlaybackTests {
    /// Waits (up to `timeout` seconds) for a condition on the main actor.
    private func wait(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func openThreeSceneVideo() async throws -> (VideoModel, URL) {
        let url = try await makeTestVideo(segments: [
            .solid(220, 30, 30, frames: 30),
            .solid(30, 30, 220, frames: 30),
            .horizontalGradient(frames: 30),
        ])
        let model = VideoModel()
        await model.open(url)
        let found = await wait(timeout: 15) { model.scenes.count == 3 }
        try #require(found, "expected 3 scenes, got \(model.scenes.count)")
        return (model, url)
    }

    @Test func playingASelectedScenePausesAtTheStartOfTheNext() async throws {
        let (model, url) = try await openThreeSceneVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        model.selectedSceneIndex = 0
        model.player.play()

        // It should stop by itself at ~1.0 s (the start of scene 2) rather than playing on.
        let paused = await wait(timeout: 6) { model.player.timeControlStatus == .paused && model.player.currentTime().seconds > 0.5 }
        #expect(paused)
        let stoppedAt = model.player.currentTime().seconds
        #expect(abs(stoppedAt - 1.0) < 0.1, "stopped at \(stoppedAt)")

        // ...and the next scene is now cued, so another press of play runs it.
        let advanced = await wait(timeout: 2) { model.selectedSceneIndex == 1 }
        #expect(advanced)
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(model.player.currentTime().seconds - 1.0) < 0.1, "player moved on without play")
    }

    @Test func selectingASceneCuesItAtItsStartWithoutPlaying() async throws {
        let (model, url) = try await openThreeSceneVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        model.selectedSceneIndex = 2
        let cued = await wait(timeout: 3) { abs(model.player.currentTime().seconds - 2.0) < 0.1 }
        #expect(cued, "at \(model.player.currentTime().seconds)")
        #expect(model.player.timeControlStatus == .paused)
    }

    @Test func thumbnailsAreGeneratedForEveryScene() async throws {
        let (model, url) = try await openThreeSceneVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = await wait(timeout: 10) { model.thumbnails.count == 3 }
        #expect(loaded, "thumbnails: \(model.thumbnails.keys.sorted())")
        #expect(model.thumbnails.values.allSatisfy { $0.width > 0 && $0.width <= 240 })
    }

    @Test func selectingTheCurrentSceneAgainRecuesIt() async throws {
        let (model, url) = try await openThreeSceneVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        model.selectScene(1)
        let cued = await wait(timeout: 3) { abs(model.player.currentTime().seconds - 1.0) < 0.1 }
        #expect(cued)

        // Move the playhead away without going through the model (as playing would), then pick the same scene again.
        await model.player.seek(to: CMTime(seconds: 1.8, preferredTimescale: 600))
        model.selectScene(1)
        let recued = await wait(timeout: 3) { abs(model.player.currentTime().seconds - 1.0) < 0.1 }
        #expect(recued, "at \(model.player.currentTime().seconds)")
    }

    @Test func playheadFollowsScrubbing() async throws {
        let (model, url) = try await openThreeSceneVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        model.seek(to: 1.5)
        let followed = await wait(timeout: 3) { abs(model.currentSeconds - 1.5) < 0.1 }
        #expect(followed, "currentSeconds = \(model.currentSeconds)")
    }

    @Test func timelineSeekClearsTheSceneLimit() async throws {
        let (model, url) = try await openThreeSceneVideo()
        defer { try? FileManager.default.removeItem(at: url) }

        model.selectedSceneIndex = 0
        model.seek(to: 0.5)
        #expect(model.selectedSceneIndex == nil)
        #expect(model.player.currentItem?.forwardPlaybackEndTime.isValid == false)
    }
}
