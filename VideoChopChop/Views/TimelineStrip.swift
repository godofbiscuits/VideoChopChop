//
//  TimelineStrip.swift
//  VideoChopChop
//

import SwiftUI

/// A strip showing every scene as a block; click anywhere to seek.
struct TimelineStrip: View {
    let scenes: [SceneSegment]
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                ForEach(scenes) { scene in
                    Rectangle()
                        .fill(scene.index.isMultiple(of: 2) ? Color.accentColor.opacity(0.55) : Color.accentColor.opacity(0.3))
                        .frame(width: max(width * scene.duration / max(duration, 0.001) - 1, 1))
                        .offset(x: width * scene.startTime / max(duration, 0.001))
                }
            }
            .frame(maxHeight: .infinity)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                onSeek(min(max(point.x / width, 0), 1) * duration)
            }
        }
        .frame(height: 28)
        .accessibilityLabel("Scene timeline")
    }
}
