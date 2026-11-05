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

    /// Natural thumbnail width for 16:9 images, and the comfortable scale for 1 s scenes (thumbnail + 10% each side).
    private let thumbnailWidth = SceneTimelineView.thumbnailHeight * 16.0 / 9.0
    private var comfortableForOneSecondScenes: CGFloat { thumbnailWidth * 1.2 }

    @Test func zoomMultipliesTheComfortableScaleAndWidensTheView() {
        let view = makeTimeline()   // 2 x 1 s scenes in a 400 pt window
        // Comfortable (about 111 pt/s) is narrower than the window (200 pt/s), so the window wins at zoom 1.
        #expect(view.pixelsPerSecond == 200)
        #expect(view.frame.width == 400)
        view.zoom = 4
        #expect(abs(view.pixelsPerSecond - comfortableForOneSecondScenes * 4) < 0.001)
        #expect(abs(view.frame.width - 2 * comfortableForOneSecondScenes * 4) < 0.01)
    }

    @Test func shortestSceneIsWideEnoughForItsThumbnailPlusTenPercentEachSide() {
        let view = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 100, height: SceneTimelineView.totalHeight))
        view.fit(toVisibleWidth: 100)   // a narrow window, so the comfortable scale decides the width
        view.duration = 12
        view.scenes = [
            SceneSegment(index: 0, startTime: 0, endTime: 10, startFrame: 0, endFrame: 1, cutScore: 0),
            SceneSegment(index: 1, startTime: 10, endTime: 11, startFrame: 0, endFrame: 1, cutScore: 0.9),
            SceneSegment(index: 2, startTime: 11, endTime: 12, startFrame: 0, endFrame: 1, cutScore: 0.9),
        ]
        view.thumbnails = [0: solidImage(.red), 1: solidImage(.green), 2: solidImage(.blue)]

        let shortest = 1 * view.pixelsPerSecond
        #expect(abs(shortest - comfortableForOneSecondScenes) < 0.01, "shortest scene is \(shortest) pt")
        #expect(abs(10 * view.pixelsPerSecond - 10 * comfortableForOneSecondScenes) < 0.1)   // proportional
        #expect(view.frame.width > 100, "the view should be wider than the window so it scrolls")
        #expect(abs(view.frame.width - 12 * comfortableForOneSecondScenes) < 0.1)
    }

    @Test func timelineIsNeverNarrowerThanTheWindowAndZoomOutStopsThere() {
        let view = makeTimeline()          // 400 pt window, 2 s
        view.zoom = 0.01
        #expect(view.pixelsPerSecond == 200)
        #expect(view.frame.width == 400)
    }

    @Test func widthIsCappedForVeryLongVideos() {
        let view = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 400, height: SceneTimelineView.totalHeight))
        view.fit(toVisibleWidth: 400)
        view.duration = 100_000
        view.scenes = [
            SceneSegment(index: 0, startTime: 0, endTime: 1, startFrame: 0, endFrame: 1, cutScore: 0),
            SceneSegment(index: 1, startTime: 1, endTime: 100_000, startFrame: 0, endFrame: 1, cutScore: 0.9),
        ]
        #expect(view.frame.width <= SceneTimelineView.maxDocumentWidth + 1)
    }

    // MARK: Zoom

    /// Two 20 s scenes (red then blue thumbnails), so each scene is wider than its thumbnail at the zooms below.
    private func makeZoomableTimeline(playheadAtEnd: Bool = true) -> SceneTimelineView {
        let view = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 400, height: SceneTimelineView.totalHeight))
        view.fit(toVisibleWidth: 400)
        view.duration = 40
        view.scenes = [
            SceneSegment(index: 0, startTime: 0, endTime: 20, startFrame: 0, endFrame: 1, cutScore: 0),
            SceneSegment(index: 1, startTime: 20, endTime: 40, startFrame: 0, endFrame: 1, cutScore: 0.9),
        ]
        view.thumbnails = [0: solidImage(.red), 1: solidImage(.blue)]
        view.playhead = playheadAtEnd ? 40 : 0   // keep the red playhead away from the red thumbnail
        return view
    }

    /// Size in points of the red thumbnail of scene 0, measured along the spine and down the middle of the scene.
    private func redThumbnailExtent(_ view: SceneTimelineView) throws -> (width: CGFloat, height: CGFloat) {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func isRed(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > 0.8 && c.greenComponent < 0.3 && c.blueComponent < 0.3
        }
        let sceneWidth = TimelineGeometry.x(forTime: 20, pixelsPerSecond: view.pixelsPerSecond)
        let spineY = Int((SceneTimelineView.rulerHeight + SceneTimelineView.trackHeight / 2) * scale)
        let centerX = Int(sceneWidth / 2 * scale)
        let width = (4..<Int((sceneWidth - 4) * scale)).filter { isRed($0, spineY) }.count
        let height = (0..<rep.pixelsHigh).filter { isRed(centerX, $0) }.count
        return (CGFloat(width) / scale, CGFloat(height) / scale)
    }

    @Test func zoomingChangesTheTimeScaleButNotTheThumbnailSize() throws {
        let view = makeZoomableTimeline()
        let before = try redThumbnailExtent(view)
        let pixelsPerSecondBefore = view.pixelsPerSecond

        view.zoomBy(2, anchoredAtX: 100)
        #expect(view.pixelsPerSecond > pixelsPerSecondBefore, "zooming in should widen the time scale")
        let after = try redThumbnailExtent(view)

        // The thumbnail is the same size (about 92 x 52 pt, less its border) at both zooms.
        #expect(abs(after.width - before.width) <= 2, "width \(before.width) -> \(after.width)")
        #expect(abs(after.height - before.height) <= 2, "height \(before.height) -> \(after.height)")
        #expect(abs(before.width - thumbnailWidth) < 4 && abs(before.height - SceneTimelineView.thumbnailHeight) < 4)
    }

    @Test func narrowScenesClipTheThumbnailInsteadOfShrinkingIt() throws {
        let view = makeZoomableTimeline()
        view.zoomBy(0.001, anchoredAtX: 0)    // all the way out: 20 s scenes are now only 200 pt wide
        view.zoom = view.minimumZoom
        let wide = try redThumbnailExtent(view)
        // Squeeze each scene to ~60 pt, narrower than the 92 pt thumbnail, by narrowing the window and zooming out fully.
        view.fit(toVisibleWidth: 120)
        view.zoom = view.minimumZoom
        let narrow = try redThumbnailExtent(view)
        #expect(abs(narrow.height - wide.height) <= 2, "height \(wide.height) -> \(narrow.height)")
        #expect(narrow.width < wide.width, "the thumbnail is clipped, not scaled")
    }

    @Test func zoomIsAnchoredOnThePointer() throws {
        let scrollView = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: SceneTimelineView.totalHeight + 18))
        let timeline = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 300, height: SceneTimelineView.totalHeight))
        scrollView.documentView = timeline
        timeline.duration = 6
        timeline.scenes = (0..<6).map {
            SceneSegment(index: $0, startTime: Double($0), endTime: Double($0 + 1), startFrame: 0, endFrame: 1, cutScore: 0)
        }
        timeline.thumbnails = Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, solidImage(.red)) })
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 100, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let anchorX: CGFloat = 150                                   // document coordinates; 50 pt into the window
        let anchorTime = TimelineGeometry.time(forX: anchorX, pixelsPerSecond: timeline.pixelsPerSecond)
        timeline.zoomBy(2, anchoredAtX: anchorX)

        let newOrigin = scrollView.contentView.bounds.origin.x
        let timeUnderPointer = TimelineGeometry.time(forX: newOrigin + 50, pixelsPerSecond: timeline.pixelsPerSecond)
        #expect(abs(timeUnderPointer - anchorTime) < 0.01, "\(anchorTime) s drifted to \(timeUnderPointer) s")
    }

    @Test func zoomIsClampedAndReported() {
        let view = makeZoomableTimeline()
        var reported: [Double] = []
        view.onZoomChange = { reported.append($0) }

        view.zoomBy(1_000_000, anchoredAtX: 0)
        #expect(view.zoom == SceneTimelineView.maxZoom)
        view.zoomBy(0.000_001, anchoredAtX: 0)
        #expect(view.zoom == view.minimumZoom)
        #expect(view.frame.width == 400, "fully zoomed out the timeline is exactly the window wide")
        #expect(reported == [SceneTimelineView.maxZoom, view.minimumZoom])

        // Already at the limit: nothing changes and nothing is reported.
        view.zoomBy(0.5, anchoredAtX: 0)
        #expect(reported.count == 2)
    }

    @Test func optionScrollZoomsAndPlainScrollDoesNot() throws {
        let scrollView = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: SceneTimelineView.totalHeight + 18))
        let timeline = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 300, height: SceneTimelineView.totalHeight))
        scrollView.documentView = timeline
        timeline.duration = 6
        timeline.scenes = (0..<6).map {
            SceneSegment(index: $0, startTime: Double($0), endTime: Double($0 + 1), startFrame: 0, endFrame: 1, cutScore: 0)
        }
        timeline.thumbnails = [0: solidImage(.red)]
        scrollView.layoutSubtreeIfNeeded()

        func scrollEvent(_ delta: Int32, option: Bool) throws -> NSEvent {
            let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            if option { cgEvent.flags = .maskAlternate }
            return try #require(NSEvent(cgEvent: cgEvent))
        }
        let start = timeline.zoom
        scrollView.scrollWheel(with: try scrollEvent(-80, option: false))
        #expect(timeline.zoom == start, "plain scrolling must not zoom")

        scrollView.scrollWheel(with: try scrollEvent(40, option: true))
        #expect(timeline.zoom > start, "option + scroll up zooms in")
        let zoomedIn = timeline.zoom
        scrollView.scrollWheel(with: try scrollEvent(-40, option: true))
        #expect(timeline.zoom < zoomedIn, "option + scroll down zooms out")
    }

    @Test func scrollViewScrollsAndAMouseWheelMovesItSideways() throws {
        let scrollView = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: SceneTimelineView.totalHeight + 18))
        scrollView.hasHorizontalScroller = true
        let timeline = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 300, height: SceneTimelineView.totalHeight))
        scrollView.documentView = timeline
        timeline.duration = 6
        timeline.scenes = (0..<6).map {
            SceneSegment(index: $0, startTime: Double($0), endTime: Double($0 + 1), startFrame: 0, endFrame: 1, cutScore: 0)
        }
        timeline.thumbnails = Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, solidImage(.red)) })
        scrollView.layoutSubtreeIfNeeded()

        #expect(timeline.frame.width > scrollView.contentSize.width, "6 scenes at the comfortable scale are wider than a 300 pt window")
        #expect(scrollView.contentView.bounds.origin.x == 0)

        // Scrolling the wheel "down" (negative delta) scrolls the timeline to the right.
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -80, wheel2: 0, wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        scrollView.scrollWheel(with: event)
        #expect(scrollView.contentView.bounds.origin.x > 0, "x = \(scrollView.contentView.bounds.origin.x)")
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
