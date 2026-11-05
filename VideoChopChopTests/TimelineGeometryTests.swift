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

    @Test func degenerateInputsAreSafe() {
        #expect(TimelineGeometry.time(forX: 10, width: 0, duration: 10) == 0)
        #expect(TimelineGeometry.time(forX: 10, width: 100, duration: 0) == 0)
        #expect(TimelineGeometry.x(forTime: 5, width: 100, duration: 0) == 0)
    }
}
