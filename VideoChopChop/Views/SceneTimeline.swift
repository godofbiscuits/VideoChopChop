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

    /// Widest the timeline will ever be, in points, however many short scenes a long video has.
    static let maxDocumentWidth: CGFloat = 120_000

    var scenes: [SceneSegment] = [] { didSet { relayout() } }
    var thumbnails: [Int: CGImage] = [:] { didSet { relayout() } }
    var duration = 0.0 { didSet { relayout() } }
    /// Multiplies the comfortable scale (smallest typical scene = thumbnail + 10% each side). Below 1 zooms out,
    /// but the timeline is never narrower than the window.
    var zoom = 1.0 { didSet { relayout() } }
    var playhead = 0.0 { didSet { playheadMoved() } }
    var selectedSceneIndex: Int? { didSet { needsDisplay = true } }

    /// Click or drag in the ruler: scrub to a time.
    var onScrub: ((Double) -> Void)?
    /// Click on a scene in the track: select it (cue its start; play stops at the next scene).
    var onSelectScene: ((Int) -> Void)?
    /// A movie file was dropped on the timeline.
    var onDropVideo: ((URL) -> Void)?
    /// Shown in the empty track (no video yet, or analysis in progress).
    var placeholder: String? { didSet { needsDisplay = true } }
    private(set) var isDropTargeted = false { didSet { needsDisplay = true } }

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
        registerForDraggedTypes(VideoDrop.draggedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    func fit(toVisibleWidth width: CGFloat) {
        guard width != visibleWidth else { return }
        visibleWidth = width
        relayout()
    }

    /// A thumbnail's natural width, from the first thumbnail's aspect ratio (16:9 until one arrives).
    private var naturalThumbnailWidth: CGFloat {
        let aspect = thumbnails.values.first.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16.0 / 9.0
        return Self.thumbnailHeight * aspect
    }

    private func relayout() {
        guard duration > 0 else {
            pixelsPerSecond = 0
            setFrameSize(NSSize(width: visibleWidth, height: Self.totalHeight))
            needsDisplay = true
            return
        }
        let fitToWindow = visibleWidth / CGFloat(duration)
        let comfortable = TimelineGeometry.comfortablePixelsPerSecond(scenes: scenes, thumbnailWidth: naturalThumbnailWidth)
        let capped = min(comfortable * CGFloat(zoom), Self.maxDocumentWidth / CGFloat(duration))
        pixelsPerSecond = max(fitToWindow, capped)
        setFrameSize(NSSize(width: max(visibleWidth, CGFloat(duration) * pixelsPerSecond), height: Self.totalHeight))
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

        // The horizontal spine the thumbnails sit on (left out when empty, so it doesn't strike through the message).
        if !scenes.isEmpty {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: midY - 0.5, width: bounds.width, height: 1).fill()
        }

        for scene in scenes { draw(scene, midY: midY) }
        drawPlaceholder(midY: midY)

        // Marker at the start of every scene.
        NSColor.systemYellow.setFill()
        for scene in scenes {
            let x = TimelineGeometry.x(forTime: scene.startTime, pixelsPerSecond: pixelsPerSecond)
            NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }

        drawPlayhead()

        if isDropTargeted {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            border.stroke()
        }
    }

    private func drawPlaceholder(midY: CGFloat) {
        guard scenes.isEmpty, let placeholder else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = placeholder as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        // Centered in the visible part of the (possibly scrolled) view, not the whole document.
        // (A view outside any window reports an unbounded visibleRect, so clamp it to our bounds.)
        let visible = visibleRect.intersection(bounds)
        let area = visible.isNull || visible.isEmpty ? bounds : visible
        let height = text.size(withAttributes: attributes).height
        text.draw(in: NSRect(x: area.minX, y: midY - height / 2, width: area.width, height: height), withAttributes: attributes)
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
        guard duration > 0 else { return }   // nothing to point at before a video is loaded
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

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = VideoDrop.operation(for: sender.draggingPasteboard)
        isDropTargeted = operation != []
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        VideoDrop.operation(for: sender.draggingPasteboard)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTargeted = false }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        VideoDrop.videoURL(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTargeted = false
        return acceptDrop(from: sender.draggingPasteboard)
    }

    /// Hands a dropped movie to `onDropVideo`; returns false for anything else.
    func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard let url = VideoDrop.videoURL(from: pasteboard) else { return false }
        onDropVideo?(url)
        return true
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

    /// A plain mouse wheel only reports vertical movement; there is nothing to scroll vertically,
    /// so use it to scroll the timeline sideways. Trackpad swipes with a horizontal part pass through unchanged.
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let maxX = max(document.frame.width - contentView.bounds.width, 0)
        let x = min(max(contentView.bounds.origin.x - step, 0), maxX)
        contentView.scroll(to: NSPoint(x: x, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}

struct SceneTimeline: NSViewRepresentable {
    let scenes: [SceneSegment]
    let thumbnails: [Int: CGImage]
    let duration: Double
    let playhead: Double
    let selectedSceneIndex: Int?
    let zoom: Double
    let placeholder: String?
    let onScrub: (Double) -> Void
    let onSelectScene: (Int) -> Void
    let onDropVideo: (URL) -> Void

    func makeNSView(context: Context) -> TimelineScrollView {
        let scrollView = TimelineScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        // A permanent scroll bar, so it's obvious the timeline scrolls.
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
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
        timeline.placeholder = placeholder
        timeline.onScrub = onScrub
        timeline.onSelectScene = onSelectScene
        timeline.onDropVideo = onDropVideo
    }
}
