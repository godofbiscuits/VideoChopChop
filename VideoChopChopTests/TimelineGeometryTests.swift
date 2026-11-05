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

    @Test func thumbnailIsCenteredBetweenMarkers() {
        let rect = TimelineGeometry.centeredThumbnailRect(
            startX: 100, endX: 300, thumbnailSize: CGSize(width: 80, height: 45), centerY: 60
        )
        #expect(rect.midX == 200)
        #expect(rect.midY == 60)
        #expect(rect.size == CGSize(width: 80, height: 45))
    }

    @Test func shortScenesShrinkTheThumbnailDownToAFloor() {
        let natural = CGSize(width: 92, height: 52)
        // Plenty of room: unchanged. Short scene: scaled to fit with a margin. Tiny scene: floored at 40%.
        #expect(TimelineGeometry.fittedThumbnailSize(natural: natural, sceneWidth: 300) == natural)
        let fitted = TimelineGeometry.fittedThumbnailSize(natural: natural, sceneWidth: 56)
        #expect(abs(fitted.width - 50) < 0.001 && abs(fitted.width / fitted.height - 92.0 / 52.0) < 0.001)
        let floored = TimelineGeometry.fittedThumbnailSize(natural: natural, sceneWidth: 10)
        #expect(abs(floored.width - 36.8) < 0.001)
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
