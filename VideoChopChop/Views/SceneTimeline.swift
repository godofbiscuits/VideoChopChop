//
//  SceneTimeline.swift
//  VideoChopChop
//

import AppKit
import SwiftUI

/// Scene blocks, the selected scene, and a playhead. Click or drag anywhere to scrub.
final class SceneTimelineView: NSView {
    var scenes: [SceneSegment] = [] { didSet { needsDisplay = true } }
    var duration = 0.0 { didSet { needsDisplay = true } }
    var playhead = 0.0 { didSet { needsDisplay = true } }
    var selectedSceneIndex: Int? { didSet { needsDisplay = true } }
    /// Called with the video time under the pointer, on press and while dragging.
    var onScrub: ((Double) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Scene timeline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        background.fill()
        background.addClip()

        for scene in scenes {
            let x0 = TimelineGeometry.x(forTime: scene.startTime, width: bounds.width, duration: duration)
            let x1 = TimelineGeometry.x(forTime: scene.endTime, width: bounds.width, duration: duration)
            let isSelected = scene.index == selectedSceneIndex
            let color = NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.9 : (scene.index.isMultiple(of: 2) ? 0.5 : 0.3))
            color.setFill()
            NSRect(x: x0, y: 0, width: max(x1 - x0 - 1, 1), height: bounds.height).fill()
        }

        let x = TimelineGeometry.x(forTime: playhead, width: bounds.width, duration: duration)
        NSColor.labelColor.setFill()
        NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    private func scrub(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onScrub?(TimelineGeometry.time(forX: point.x, width: bounds.width, duration: duration))
    }
}

struct SceneTimeline: NSViewRepresentable {
    let scenes: [SceneSegment]
    let duration: Double
    let playhead: Double
    let selectedSceneIndex: Int?
    let onScrub: (Double) -> Void

    func makeNSView(context: Context) -> SceneTimelineView { SceneTimelineView() }

    func updateNSView(_ view: SceneTimelineView, context: Context) {
        view.scenes = scenes
        view.duration = duration
        view.playhead = playhead
        view.selectedSceneIndex = selectedSceneIndex
        view.onScrub = onScrub
    }
}
