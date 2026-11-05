//
//  ScanProgressTests.swift
//  VideoChopChopTests
//

import AppKit
import Foundation
import Testing
@testable import VideoChopChop

struct ScanProgressLayoutTests {
    @Test func formatsTheClock() {
        #expect(ScanProgressLayout.clock(0) == "0:00")
        #expect(ScanProgressLayout.clock(9.9) == "0:09")
        #expect(ScanProgressLayout.clock(75) == "1:15")
        #expect(ScanProgressLayout.clock(3599) == "59:59")
        #expect(ScanProgressLayout.clock(3723) == "1:02:03")
        #expect(ScanProgressLayout.clock(-5) == "0:00")
    }

    @Test func formatsTheFrameText() {
        #expect(ScanProgressLayout.frameText(frame: 1234, totalFrames: 72000) == "Frame \(1234.formatted()) of \(72000.formatted())")
    }

    @Test func centersThePillOnTheHeadAndKeepsItInsideTheBar() {
        // 40 pt label on a 400 pt bar.
        #expect(ScanProgressLayout.pillMinX(headX: 200, pillWidth: 40, barWidth: 400) == 180)
        #expect(ScanProgressLayout.pillMinX(headX: 0, pillWidth: 40, barWidth: 400) == 0)
        #expect(ScanProgressLayout.pillMinX(headX: 400, pillWidth: 40, barWidth: 400) == 360)
        #expect(ScanProgressLayout.pillMinX(headX: 10, pillWidth: 40, barWidth: 400) == 0)
        #expect(ScanProgressLayout.pillMinX(headX: 395, pillWidth: 40, barWidth: 400) == 360)
        #expect(ScanProgressLayout.pillMinX(headX: 20, pillWidth: 40, barWidth: 30) == 0, "a pill wider than the bar just sits at the start")
    }

    @Test func headPositionIsClamped() {
        #expect(ScanProgressLayout.headX(fraction: 0.25, width: 400) == 100)
        #expect(ScanProgressLayout.headX(fraction: -1, width: 400) == 0)
        #expect(ScanProgressLayout.headX(fraction: 7, width: 400) == 400)
    }

    @Test func progressFractionComesFromTheTimestamp() {
        #expect(AnalysisProgress(frame: 50, totalFrames: 100, seconds: 5, duration: 20).fraction == 0.25)
        #expect(AnalysisProgress(frame: 50, totalFrames: 100, seconds: 99, duration: 20).fraction == 1)
        // Without a duration it falls back to frame counts.
        #expect(AnalysisProgress(frame: 50, totalFrames: 100, seconds: 0, duration: 0).fraction == 0.5)
    }
}

@MainActor
struct ScanProgressViewTests {
    private func makeBar(fraction: Double, label: String = "1:23") -> ScanProgressNSView {
        let view = ScanProgressNSView(frame: NSRect(x: 0, y: 0, width: 400, height: ScanProgressNSView.height))
        view.fraction = fraction
        view.label = label
        return view
    }

    private func color(_ view: ScanProgressNSView, x: Int, y: Int) throws -> NSColor {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return try #require(rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB))
    }

    @Test func theTimestampIsCenteredOnTheHead() {
        let bar = makeBar(fraction: 0.5)
        #expect(abs(bar.pillRect.midX - 200) < 0.5)
        #expect(abs(bar.pillRect.midY - ScanProgressNSView.height / 2) < 0.5)
    }

    @Test func theTimestampMovesWithTheHead() {
        let bar = makeBar(fraction: 0.25)
        let early = bar.pillRect.midX
        bar.fraction = 0.75
        #expect(bar.pillRect.midX > early + 150, "\(early) -> \(bar.pillRect.midX)")
        bar.label = "1:02:03"
        #expect(bar.pillRect.width > makeBar(fraction: 0.75, label: "1:23").pillRect.width, "a longer timestamp gets a wider pill")
    }

    @Test func theTimestampStaysInsideTheBarAtBothEnds() {
        let start = makeBar(fraction: 0)
        #expect(start.pillRect.minX == 0)
        let end = makeBar(fraction: 1)
        #expect(abs(end.pillRect.maxX - 400) < 0.5)
        #expect(end.pillRect.minX >= 0)
    }

    @Test func drawsFillBehindTheHeadTrackAheadAndAPillOnTheHead() throws {
        let bar = makeBar(fraction: 0.5)
        let midY = Int(ScanProgressNSView.height / 2)

        // Behind the head (clear of the pill): solid accent fill.
        let filled = try color(bar, x: 40, y: midY)
        #expect(filled.alphaComponent > 0.9)
        // Ahead of the head: the faint track.
        let track = try color(bar, x: 360, y: midY)
        #expect(track.alphaComponent < 0.5, "track alpha \(track.alphaComponent)")

        // The pill is taller than the bar, so just above the bar, directly over the head, only the pill is drawn.
        // (Sampled at the top of the pill's rounded end: its straight corner would be outside the curve.)
        let abovePill = try color(bar, x: Int(bar.pillRect.minX + bar.pillRect.height / 2), y: Int(bar.pillRect.minY) + 3)
        #expect(abovePill.alphaComponent > 0.9, "pill should be opaque over the head")
        let aboveBarElsewhere = try color(bar, x: 40, y: Int(bar.pillRect.minY) + 2)
        #expect(aboveBarElsewhere.alphaComponent < 0.1, "nothing is drawn above the bar away from the head")
    }
}

struct ScanProgressFromDetectorTests {
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [AnalysisProgress] = []
        func add(_ update: AnalysisProgress) { lock.lock(); all.append(update); lock.unlock() }
        var values: [AnalysisProgress] { lock.lock(); defer { lock.unlock() }; return all }
    }

    @Test func reportsFrameAndTimestampProgressEndingExactlyAtTheLastFrame() async throws {
        let url = try await makeTestVideo(segments: [.solid(220, 30, 30, frames: 45), .solid(30, 30, 220, frames: 45)])
        defer { try? FileManager.default.removeItem(at: url) }

        var config = SceneCutConfig()
        config.confirmWithVision = false
        let updates = Updates()
        _ = try await SceneCutDetector().analyze(url: url, config: config) { updates.add($0) }

        let values = updates.values
        let first = try #require(values.first), last = try #require(values.last)
        // 3 s at 30 fps: the estimate made before reading any frames is already 90.
        #expect(first.totalFrames == 90, "estimated total \(first.totalFrames)")
        #expect(values.allSatisfy { $0.frame <= $0.totalFrames })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.frame <= $1.frame && $0.seconds <= $1.seconds }, "progress only moves forward")
        #expect(values.count > 5, "regular updates, not just the end")
        // Finished: the exact count, with the head at the end.
        #expect(last.frame == 90 && last.totalFrames == 90)
        #expect(last.fraction == 1)
    }
}
