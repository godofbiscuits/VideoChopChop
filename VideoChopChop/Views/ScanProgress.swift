//
//  ScanProgress.swift
//  VideoChopChop
//
//  The progress display for a scene scan: "Frame N of M" above a bar whose head carries the movie's
//  current timestamp, centered on the head and moving with it.
//

import AppKit
import SwiftUI

/// Pure layout and formatting, kept separate so it can be tested.
nonisolated enum ScanProgressLayout {
    static func headX(fraction: Double, width: CGFloat) -> CGFloat {
        min(max(CGFloat(fraction), 0), 1) * width
    }

    /// Left edge for a label of `pillWidth` centered on the head, nudged inward so it never leaves the bar.
    static func pillMinX(headX: CGFloat, pillWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
        guard barWidth > pillWidth else { return 0 }
        return min(max(headX - pillWidth / 2, 0), barWidth - pillWidth)
    }

    /// "m:ss", or "h:mm:ss" from one hour up.
    static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        let two = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(m):\(two(s))"
    }

    static func frameText(frame: Int, totalFrames: Int) -> String {
        "Frame \(frame.formatted()) of \(totalFrames.formatted())"
    }
}

final class ScanProgressNSView: NSView {
    static let height: CGFloat = 24
    private static let barThickness: CGFloat = 8
    private static let pillHeight: CGFloat = 22
    private static let pillPadding: CGFloat = 8

    var fraction = 0.0 { didSet { needsDisplay = true } }
    /// The timestamp shown on the head.
    var label = "0:00" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Scene scan progress")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
    }

    /// The pill that carries the timestamp: centered on the head, clamped inside the bar.
    var pillRect: NSRect {
        let textWidth = (label as NSString).size(withAttributes: labelAttributes).width
        let width = ceil(textWidth) + Self.pillPadding * 2
        let headX = ScanProgressLayout.headX(fraction: fraction, width: bounds.width)
        return NSRect(
            x: ScanProgressLayout.pillMinX(headX: headX, pillWidth: width, barWidth: bounds.width),
            y: (bounds.height - Self.pillHeight) / 2, width: min(width, bounds.width), height: Self.pillHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let barRect = NSRect(x: 0, y: (bounds.height - Self.barThickness) / 2, width: bounds.width, height: Self.barThickness)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: Self.barThickness / 2, yRadius: Self.barThickness / 2).fill()

        let headX = ScanProgressLayout.headX(fraction: fraction, width: bounds.width)
        if headX > 0 {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: barRect.minY, width: headX, height: barRect.height),
                xRadius: Self.barThickness / 2, yRadius: Self.barThickness / 2
            ).fill()
        }

        let pill = pillRect
        (NSColor.controlAccentColor.blended(withFraction: 0.3, of: .black) ?? .controlAccentColor).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        let textSize = (label as NSString).size(withAttributes: labelAttributes)
        (label as NSString).draw(
            at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2),
            withAttributes: labelAttributes
        )
        setAccessibilityValue("\(Int(fraction * 100)) percent, at \(label)")
    }
}

struct ScanProgressBar: NSViewRepresentable {
    let fraction: Double
    let label: String

    func makeNSView(context: Context) -> ScanProgressNSView { ScanProgressNSView() }

    func updateNSView(_ view: ScanProgressNSView, context: Context) {
        view.fraction = fraction
        view.label = label
    }
}

/// "Finding scene cuts… Frame N of M" over a bar whose head shows the movie's timestamp.
struct ScanProgressView: View {
    let progress: AnalysisProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Finding scene cuts…  \(ScanProgressLayout.frameText(frame: progress.frame, totalFrames: progress.totalFrames))")
                .monospacedDigit()
            ScanProgressBar(fraction: progress.fraction, label: ScanProgressLayout.clock(progress.seconds))
                .frame(height: ScanProgressNSView.height)
        }
    }
}
