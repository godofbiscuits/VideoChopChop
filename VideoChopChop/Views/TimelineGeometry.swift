//
//  TimelineGeometry.swift
//  VideoChopChop
//

import CoreGraphics

/// Pure mapping between horizontal positions and video time, kept separate so it can be tested.
nonisolated enum TimelineGeometry {
    /// Video time for a horizontal position, clamped to the video's duration.
    static func time(forX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * duration
    }

    /// Horizontal position for a video time; clamped to the view's width.
    static func x(forTime time: Double, width: CGFloat, duration: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(time / duration), 0), 1) * width
    }
}
