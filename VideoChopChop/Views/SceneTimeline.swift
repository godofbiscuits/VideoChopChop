//
//  SceneTimeline.swift
//  VideoChopChop
//
//  A Final Cut Pro style timeline: a time ruler, one horizontal spine, a vertical marker at
//  the start of every scene, and each scene's thumbnail centered between its markers.
//

import AppKit
import SwiftUI

final class SceneTimelineView: NSView {
    static let rulerHeight: CGFloat = 20
    static let trackHeight: CGFloat = 84
    static let thumbnailHeight: CGFloat = 52
    static var totalHeight: CGFloat { rulerHeight + trackHeight }

    var scenes: [SceneSegment] = [] { didSet { needsDisplay = true } }
    var thumbnails: [Int: CGImage] = [:] { didSet { needsDisplay = true } }
    var duration = 0.0 { didSet { relayout() } }
    /// 1 fits the whole video in the visible width; larger values zoom in.
    var zoom = 1.0 { didSet { relayout() } }
    var playhead = 0.0 { didSet { playheadMoved() } }
    var selectedSceneIndex: Int? { didSet { needsDisplay = true } }

    /// Click or drag in the ruler: scrub to a time.
    var onScrub: ((Double) -> Void)?
    /// Click on a scene in the track: select it (cue its start; play stops at the next scene).
    var onSelectScene: ((Int) -> Void)?

    private(set) var pixelsPerSecond: CGFloat = 0
    private var visibleWidth: CGFloat = 0
    private var isScrubbing = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Scene timeline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    func fit(toVisibleWidth width: CGFloat) {
        guard width != visibleWidth else { return }
        visibleWidth = width
        relayout()
    }

    private func relayout() {
        pixelsPerSecond = duration > 0 && visibleWidth > 0 ? visibleWidth / duration * zoom : 0
        setFrameSize(NSSize(width: max(visibleWidth, duration * pixelsPerSecond), height: Self.totalHeight))
        needsDisplay = true
    }

    private func playheadMoved() {
        needsDisplay = true
        guard !isScrubbing, pixelsPerSecond > 0 else { return }
        let x = TimelineGeometry.x(forTime: playhead, pixelsPerSecond: pixelsPerSecond)
        if x < visibleRect.minX + 8 || x > visibleRect.maxX - 8 {
            scrollToVisible(NSRect(x: x - 40, y: 0, width: 80, height: 1))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ruler = NSRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight)
        let midY = Self.rulerHeight + Self.trackHeight / 2

        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        NSColor.controlBackgroundColor.setFill()
        ruler.fill()
        drawTicks(in: dirtyRect)

        // The horizontal spine the thumbnails sit on.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: midY - 0.5, width: bounds.width, height: 1).fill()

        for scene in scenes { draw(scene, midY: midY) }

        // Marker at the start of every scene.
        NSColor.systemYellow.setFill()
        for scene in scenes {
            let x = TimelineGeometry.x(forTime: scene.startTime, pixelsPerSecond: pixelsPerSecond)
            NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }

        drawPlayhead()
    }

    private func draw(_ scene: SceneSegment, midY: CGFloat) {
        let x0 = TimelineGeometry.x(forTime: scene.startTime, pixelsPerSecond: pixelsPerSecond)
        let x1 = TimelineGeometry.x(forTime: scene.endTime, pixelsPerSecond: pixelsPerSecond)
        let sceneRect = NSRect(x: x0, y: Self.rulerHeight, width: max(x1 - x0, 1), height: Self.trackHeight)
        let isSelected = scene.index == selectedSceneIndex

        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            sceneRect.fill()
        }

        let image = thumbnails[scene.index]
        let aspect = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16.0 / 9.0
        let size = TimelineGeometry.fittedThumbnailSize(
            natural: CGSize(width: Self.thumbnailHeight * aspect, height: Self.thumbnailHeight), sceneWidth: x1 - x0
        )
        let rect = TimelineGeometry.centeredThumbnailRect(startX: x0, endX: x1, thumbnailSize: size, centerY: midY)

        // Clip to the scene so a thumbnail wider than a short scene never spills over its neighbours.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sceneRect.insetBy(dx: 2, dy: 0)).addClip()
        if let image {
            NSImage(cgImage: image, size: size)
                .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
        }
        (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = isSelected ? 2 : 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if sceneRect.width > 24 {
            ("\(scene.index + 1)" as NSString).draw(
                at: NSPoint(x: x0 + 5, y: Self.rulerHeight + 3),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }
    }

    private func drawTicks(in dirtyRect: NSRect) {
        guard pixelsPerSecond > 0 else { return }
        let interval = TimelineGeometry.tickInterval(pixelsPerSecond: pixelsPerSecond)
        let spacing = CGFloat(interval) * pixelsPerSecond
        let first = max(Int(dirtyRect.minX / spacing) - 1, 0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSColor.tertiaryLabelColor.setFill()
        var index = first
        while true {
            let time = Double(index) * interval
            let x = TimelineGeometry.x(forTime: time, pixelsPerSecond: pixelsPerSecond)
            if x > dirtyRect.maxX || time > duration { break }
            NSRect(x: x, y: Self.rulerHeight - 6, width: 1, height: 6).fill()
            (TimelineGeometry.label(forTime: time, fractional: interval < 1) as NSString)
                .draw(at: NSPoint(x: x + 3, y: 3), withAttributes: attributes)
            index += 1
        }
    }

    private func drawPlayhead() {
        let x = TimelineGeometry.x(forTime: playhead, pixelsPerSecond: pixelsPerSecond)
        NSColor.systemRed.setFill()
        NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x - 5, y: 0))
        head.line(to: NSPoint(x: x + 5, y: 0))
        head.line(to: NSPoint(x: x, y: 8))
        head.close()
        head.fill()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < Self.rulerHeight {
            isScrubbing = true
            scrub(toX: point.x)
        } else if let index = TimelineGeometry.sceneIndex(atX: point.x, scenes: scenes, pixelsPerSecond: pixelsPerSecond) {
            onSelectScene?(index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbing else { return }
        scrub(toX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { isScrubbing = false }

    private func scrub(toX x: CGFloat) {
        onScrub?(min(TimelineGeometry.time(forX: x, pixelsPerSecond: pixelsPerSecond), duration))
    }
}

/// Keeps the timeline sized to the visible width (times the zoom) as the window resizes.
final class TimelineScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? SceneTimelineView)?.fit(toVisibleWidth: contentSize.width)
    }
}

struct SceneTimeline: NSViewRepresentable {
    let scenes: [SceneSegment]
    let thumbnails: [Int: CGImage]
    let duration: Double
    let playhead: Double
    let selectedSceneIndex: Int?
    let zoom: Double
    let onScrub: (Double) -> Void
    let onSelectScene: (Int) -> Void

    func makeNSView(context: Context) -> TimelineScrollView {
        let scrollView = TimelineScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 100, height: SceneTimelineView.totalHeight))
        return scrollView
    }

    func updateNSView(_ scrollView: TimelineScrollView, context: Context) {
        guard let timeline = scrollView.documentView as? SceneTimelineView else { return }
        timeline.scenes = scenes
        timeline.thumbnails = thumbnails
        timeline.duration = duration
        timeline.zoom = zoom
        timeline.playhead = playhead
        timeline.selectedSceneIndex = selectedSceneIndex
        timeline.onScrub = onScrub
        timeline.onSelectScene = onSelectScene
    }
}
