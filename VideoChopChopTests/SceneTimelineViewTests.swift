//
//  SceneTimelineViewTests.swift
//  VideoChopChopTests
//
//  Renders the AppKit timeline to a bitmap and checks real pixels, since the UI can't be eyeballed in tests.
//

import AppKit
import Testing
@testable import VideoChopChop

@MainActor
struct SceneTimelineViewTests {
    private func solidImage(_ color: NSColor, width: Int = 32, height: Int = 18) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Two 1-second scenes in a 400 pt wide timeline: scene 1 spans x 0...200, scene 2 spans 200...400.
    private func makeTimeline(playhead: Double = 0, selected: Int? = nil) -> SceneTimelineView {
        let view = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 400, height: SceneTimelineView.totalHeight))
        view.fit(toVisibleWidth: 400)
        view.duration = 2
        view.scenes = [
            SceneSegment(index: 0, startTime: 0, endTime: 1, startFrame: 0, endFrame: 30, cutScore: 0),
            SceneSegment(index: 1, startTime: 1, endTime: 2, startFrame: 30, endFrame: 60, cutScore: 0.9),
        ]
        view.thumbnails = [0: solidImage(.red), 1: solidImage(.blue)]
        view.playhead = playhead
        view.selectedSceneIndex = selected
        return view
    }

    /// Renders the view and returns the pixel at (x, y) measured from the top-left.
    private func pixel(_ view: SceneTimelineView, x: Int, y: Int) throws -> NSColor {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return try #require(rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB))
    }

    private let spineY = Int(SceneTimelineView.rulerHeight + SceneTimelineView.trackHeight / 2)

    @Test func intrinsicSizeAndZoom() {
        let view = makeTimeline()
        #expect(view.frame.width == 400)
        #expect(view.pixelsPerSecond == 200)
        view.zoom = 4
        #expect(view.pixelsPerSecond == 800)
        #expect(view.frame.width == 1600)
    }

    @Test func thumbnailsAreCenteredBetweenMarkers() throws {
        let view = makeTimeline()
        let first = try pixel(view, x: 100, y: spineY)    // middle of scene 1
        let second = try pixel(view, x: 300, y: spineY)   // middle of scene 2
        #expect(first.redComponent > 0.8 && first.blueComponent < 0.3, "scene 1 thumbnail should be red: \(first)")
        #expect(second.blueComponent > 0.8 && second.redComponent < 0.3, "scene 2 thumbnail should be blue: \(second)")
    }

    @Test func thumbnailsSitOnTheSpineAndDoNotFillTheTrack() throws {
        let view = makeTimeline()
        // 52 pt thumbnails centered on the spine leave the top and bottom of the 84 pt track empty.
        let aboveThumb = try pixel(view, x: 100, y: Int(SceneTimelineView.rulerHeight) + 4)
        #expect(!(aboveThumb.redComponent > 0.8 && aboveThumb.blueComponent < 0.3))
    }

    @Test func yellowMarkerAtEachSceneStart() throws {
        let view = makeTimeline()
        let atSecondScene = try pixel(view, x: 200, y: Int(SceneTimelineView.rulerHeight) + 6)  // above the thumbnails
        #expect(atSecondScene.redComponent > 0.8 && atSecondScene.greenComponent > 0.6 && atSecondScene.blueComponent < 0.4,
                "expected a yellow marker, got \(atSecondScene)")
    }

    @Test func playheadIsDrawnInRed() throws {
        let view = makeTimeline(playhead: 0.5)  // x = 100
        let onPlayhead = try pixel(view, x: 100, y: Int(SceneTimelineView.rulerHeight) + 4)
        #expect(onPlayhead.redComponent > 0.8 && onPlayhead.greenComponent < 0.4 && onPlayhead.blueComponent < 0.4,
                "expected the red playhead, got \(onPlayhead)")
    }

    @Test func clickingASelectsItAndRulerClickScrubs() {
        let view = makeTimeline()
        var selected: Int?
        var scrubbed: Double?
        view.onSelectScene = { selected = $0 }
        view.onScrub = { scrubbed = $0 }

        func click(x: CGFloat, y: CGFloat) {
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            view.mouseDown(with: event)
            view.mouseUp(with: event)
        }
        click(x: 300, y: 50)   // in the track, over scene 2
        #expect(selected == 1)
        #expect(scrubbed == nil)

        click(x: 100, y: 8)    // in the ruler at x = 100 → 0.5 s
        #expect(scrubbed == 0.5)
    }
}
