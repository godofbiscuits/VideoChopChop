//
//  TimelineGeometryTests.swift
//  VideoChopChopTests
//

import CoreGraphics
import Testing
@testable import VideoChopChop

struct TimelineGeometryTests {
    @Test func mapsPositionToTime() {
        #expect(TimelineGeometry.time(forX: 0, width: 200, duration: 10) == 0)
        #expect(TimelineGeometry.time(forX: 100, width: 200, duration: 10) == 5)
        #expect(TimelineGeometry.time(forX: 200, width: 200, duration: 10) == 10)
    }

    @Test func clampsOutsideTheView() {
        #expect(TimelineGeometry.time(forX: -50, width: 200, duration: 10) == 0)
        #expect(TimelineGeometry.time(forX: 500, width: 200, duration: 10) == 10)
        #expect(TimelineGeometry.x(forTime: 99, width: 200, duration: 10) == 200)
        #expect(TimelineGeometry.x(forTime: -1, width: 200, duration: 10) == 0)
    }

    @Test func roundTrips() {
        let x = TimelineGeometry.x(forTime: 3.2, width: 480, duration: 8)
        #expect(abs(TimelineGeometry.time(forX: x, width: 480, duration: 8) - 3.2) < 1e-9)
    }

    @Test func findsTheSceneUnderAPoint() {
        let scenes = [
            SceneSegment(index: 0, startTime: 0, endTime: 2, startFrame: 0, endFrame: 60, cutScore: 0),
            SceneSegment(index: 1, startTime: 2, endTime: 5, startFrame: 60, endFrame: 150, cutScore: 0.9),
        ]
        #expect(TimelineGeometry.sceneIndex(atX: 10, scenes: scenes, pixelsPerSecond: 50) == 0)
        #expect(TimelineGeometry.sceneIndex(atX: 99, scenes: scenes, pixelsPerSecond: 50) == 0)
        #expect(TimelineGeometry.sceneIndex(atX: 100, scenes: scenes, pixelsPerSecond: 50) == 1)  // marker belongs to the new scene
        #expect(TimelineGeometry.sceneIndex(atX: 400, scenes: scenes, pixelsPerSecond: 50) == nil)
    }

    @Test func findsJustTheScenesOnScreen() {
        // 1,000 scenes of 2 s each: scene i spans [2i, 2i + 2) seconds.
        let scenes = (0..<1000).map {
            SceneSegment(index: $0, startTime: Double($0) * 2, endTime: Double($0) * 2 + 2, startFrame: $0 * 60, endFrame: $0 * 60 + 60, cutScore: 0)
        }
        // At 50 pt/s a scene is 100 pt wide. A window from x = 1,050 to 1,350 overlaps scenes 10 (1000-1100), 11, 12, 13 (1300-1400).
        #expect(TimelineGeometry.visibleSceneIndices(scenes: scenes, minX: 1050, maxX: 1350, pixelsPerSecond: 50) == 10..<14)
        // Touching a boundary does not pull in the neighbour.
        #expect(TimelineGeometry.visibleSceneIndices(scenes: scenes, minX: 100, maxX: 200, pixelsPerSecond: 50) == 1..<2)
        #expect(TimelineGeometry.visibleSceneIndices(scenes: scenes, minX: 0, maxX: 100_000, pixelsPerSecond: 50) == 0..<1000)
        #expect(TimelineGeometry.visibleSceneIndices(scenes: scenes, minX: 500_000, maxX: 600_000, pixelsPerSecond: 50).isEmpty)
        #expect(TimelineGeometry.visibleSceneIndices(scenes: [], minX: 0, maxX: 100, pixelsPerSecond: 50).isEmpty)
        #expect(TimelineGeometry.visibleSceneIndices(scenes: scenes, minX: 0, maxX: 100, pixelsPerSecond: 0).isEmpty)
    }

    @Test func thumbnailIsCenteredBetweenMarkers() {
        let rect = TimelineGeometry.centeredThumbnailRect(
            startX: 100, endX: 300, thumbnailSize: CGSize(width: 80, height: 45), centerY: 60
        )
        #expect(rect.midX == 200)
        #expect(rect.midY == 60)
        #expect(rect.size == CGSize(width: 80, height: 45))
    }

    @Test func shortestSceneGetsThumbnailPlusTenPercentEachSide() {
        func scene(_ i: Int, _ start: Double, _ end: Double) -> SceneSegment {
            SceneSegment(index: i, startTime: start, endTime: end, startFrame: 0, endFrame: 1, cutScore: 0)
        }
        let scenes = [scene(0, 0, 4), scene(1, 4, 4.5), scene(2, 4.5, 14.5)]
        let pps = TimelineGeometry.comfortablePixelsPerSecond(scenes: scenes, thumbnailWidth: 100)
        // Shortest scene is 0.5 s and must be 100 (thumbnail) + 10 + 10 = 120 pt wide.
        #expect(abs(pps * 0.5 - 120) < 1e-9)
        // Everything else is in proportion: the 10 s scene is 20x wider than the 0.5 s one.
        #expect(abs(pps * 10 - 2400) < 1e-9)
    }

    @Test func oneStraySubSecondSceneDoesNotSetTheScaleForALongVideo() {
        func scene(_ i: Int, _ start: Double, _ end: Double) -> SceneSegment {
            SceneSegment(index: i, startTime: start, endTime: end, startFrame: 0, endFrame: 1, cutScore: 0)
        }
        // 25 scenes: a 0.2 s stray at the end of a video made of 2-10 s scenes.
        var scenes: [SceneSegment] = []
        var time = 0.0
        for i in 0..<24 {
            let length = 2.0 + Double(i % 5) * 2        // 2, 4, 6, 8, 10, 2, ...
            scenes.append(scene(i, time, time + length))
            time += length
        }
        scenes.append(scene(24, time, time + 0.2))

        let robust = TimelineGeometry.comfortablePixelsPerSecond(scenes: scenes, thumbnailWidth: 100)
        // Reference is the 3rd-shortest scene (10th percentile of 25 -> rank 3), 2 s: 120 pt over 2 s.
        #expect(abs(robust - 60) < 1e-9)
        // The old "shortest scene" rule would have given 600 pt/s, ten times wider.
        #expect(robust < 100)
        let byTheMinimum = TimelineGeometry.comfortablePixelsPerSecond(scenes: scenes, thumbnailWidth: 100, percentile: 0)
        #expect(abs(byTheMinimum - 600) < 1e-9)
    }

    @Test func tenOrFewerScenesStillUseTheShortestOne() {
        let scenes = (0..<10).map {
            SceneSegment(index: $0, startTime: Double($0) * 3, endTime: Double($0) * 3 + ($0 == 4 ? 0.5 : 3), startFrame: 0, endFrame: 1, cutScore: 0)
        }
        #expect(abs(TimelineGeometry.comfortablePixelsPerSecond(scenes: scenes, thumbnailWidth: 100) - 240) < 1e-9)
    }

    @Test func comfortableScaleHandlesNothingToSize() {
        #expect(TimelineGeometry.comfortablePixelsPerSecond(scenes: [], thumbnailWidth: 100) == 0)
        let scenes = [SceneSegment(index: 0, startTime: 0, endTime: 5, startFrame: 0, endFrame: 1, cutScore: 0)]
        #expect(TimelineGeometry.comfortablePixelsPerSecond(scenes: scenes, thumbnailWidth: 0) == 0)
    }

    @Test func tickIntervalKeepsLabelsApart() {
        // Fully zoomed out (about 5 pt/s) ticks must be sparse; zoomed in they get dense.
        #expect(TimelineGeometry.tickInterval(pixelsPerSecond: 5) == 15)
        #expect(TimelineGeometry.tickInterval(pixelsPerSecond: 100) == 1)
        #expect(TimelineGeometry.tickInterval(pixelsPerSecond: 1000) == 0.1)
        #expect(TimelineGeometry.tickInterval(pixelsPerSecond: 0) == 3600)
    }

    @Test func formatsTickLabels() {
        #expect(TimelineGeometry.label(forTime: 0, fractional: false) == "0:00")
        #expect(TimelineGeometry.label(forTime: 75, fractional: false) == "1:15")
        #expect(TimelineGeometry.label(forTime: 61.5, fractional: true) == "1:01.5")
    }

    @Test func pixelsPerSecondMappingRoundTrips() {
        let x = TimelineGeometry.x(forTime: 4, pixelsPerSecond: 25)
        #expect(x == 100)
        #expect(TimelineGeometry.time(forX: x, pixelsPerSecond: 25) == 4)
        #expect(TimelineGeometry.time(forX: -20, pixelsPerSecond: 25) == 0)
    }

    @Test func degenerateInputsAreSafe() {
        #expect(TimelineGeometry.time(forX: 10, width: 0, duration: 10) == 0)
        #expect(TimelineGeometry.time(forX: 10, width: 100, duration: 0) == 0)
        #expect(TimelineGeometry.x(forTime: 5, width: 100, duration: 0) == 0)
    }
}
