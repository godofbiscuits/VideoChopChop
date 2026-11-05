//
//  PlayerView.swift
//  VideoChopChop
//

import AVKit
import SwiftUI

/// AppKit's AVPlayerView hosted in SwiftUI.
///
/// SwiftUI's own `VideoPlayer` fails to initialize on this OS/SDK combination at launch
/// ("failed to demangle superclass of VideoPlayerView"), so the AppKit view is used directly.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
