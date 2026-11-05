//
//  TimelineGeometry.swift
//  VideoChopChop
//

import CoreGraphics

/// Pure timeline math, kept separate from the AppKit view so it can be tested.
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

    /// Video time for a horizontal position at a given zoom (never negative).
    static func time(forX x: CGFloat, pixelsPerSecond: CGFloat) -> Double {
        guard pixelsPerSecond > 0 else { return 0 }
        return max(Double(x / pixelsPerSecond), 0)
    }

    static func x(forTime time: Double, pixelsPerSecond: CGFloat) -> CGFloat {
        CGFloat(time) * pixelsPerSecond
    }

    /// The scene whose span contains `x`, if any.
    static func sceneIndex(atX x: CGFloat, scenes: [SceneSegment], pixelsPerSecond: CGFloat) -> Int? {
        let time = time(forX: x, pixelsPerSecond: pixelsPerSecond)
        return scenes.first { time >= $0.startTime && time < $0.endTime }?.index
    }

    /// A thumbnail frame centered horizontally between a scene's start and end markers
    /// and vertically on the timeline's spine.
    static func centeredThumbnailRect(startX: CGFloat, endX: CGFloat, thumbnailSize: CGSize, centerY: CGFloat) -> CGRect {
        CGRect(
            x: (startX + endX) / 2 - thumbnailSize.width / 2,
            y: centerY - thumbnailSize.height / 2,
            width: thumbnailSize.width, height: thumbnailSize.height
        )
    }

    /// Scales a thumbnail down (keeping its aspect ratio) so it fits inside a short scene,
    /// but never below `minScale` of its natural size; below that it is clipped to the scene instead.
    static func fittedThumbnailSize(natural: CGSize, sceneWidth: CGFloat, margin: CGFloat = 6, minScale: CGFloat = 0.4) -> CGSize {
        guard natural.width > 0, sceneWidth > 0 else { return natural }
        let scale = min(max((sceneWidth - margin) / natural.width, minScale), 1)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    /// Seconds between ruler ticks, chosen so labels stay at least `minSpacing` points apart.
    static func tickInterval(pixelsPerSecond: CGFloat, minSpacing: CGFloat = 70) -> Double {
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        guard pixelsPerSecond > 0 else { return candidates[candidates.count - 1] }
        return candidates.first { CGFloat($0) * pixelsPerSecond >= minSpacing } ?? candidates[candidates.count - 1]
    }

    /// "m:ss" or, for sub-second ticks, "m:ss.f".
    static func label(forTime time: Double, fractional: Bool) -> String {
        let total = max(time, 0)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        if fractional {
            let tenths = Int((total - Double(Int(total))) * 10 + 0.0001)
            return "\(minutes):" + (seconds < 10 ? "0" : "") + "\(seconds).\(tenths)"
        }
        return "\(minutes):" + (seconds < 10 ? "0" : "") + "\(seconds)"
    }
}
