//
//  PlayerView.swift
//  VideoChopChop
//

import AVKit
import SwiftUI

/// AVPlayerView that also accepts a dropped video file.
final class DroppableAVPlayerView: AVPlayerView {
    var onDropVideo: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(VideoDrop.draggedTypes)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setDropHighlight(_ isOn: Bool) {
        layer?.borderWidth = isOn ? 3 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = VideoDrop.operation(for: sender.draggingPasteboard)
        setDropHighlight(operation != [])
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        VideoDrop.operation(for: sender.draggingPasteboard)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { setDropHighlight(false) }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        VideoDrop.videoURL(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        return acceptDrop(from: sender.draggingPasteboard)
    }

    /// Hands a dropped movie to `onDropVideo`; returns false for anything else.
    func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard let url = VideoDrop.videoURL(from: pasteboard) else { return false }
        onDropVideo?(url)
        return true
    }
}

/// AppKit's AVPlayerView hosted in SwiftUI.
///
/// SwiftUI's own `VideoPlayer` fails to initialize on this OS/SDK at launch
/// ("failed to demangle superclass of VideoPlayerView"), so the AppKit view is used directly.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var onDropVideo: ((URL) -> Void)?

    func makeNSView(context: Context) -> DroppableAVPlayerView {
        let view = DroppableAVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: DroppableAVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.onDropVideo = onDropVideo
    }
}
