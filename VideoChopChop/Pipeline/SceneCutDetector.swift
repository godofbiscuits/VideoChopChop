//
//  SceneCutDetector.swift
//  VideoChopChop
//
//  Finds hard scene cuts. Each frame is shrunk on the GPU to a tiny image, converted
//  to OKLab, and compared with the previous frame by histogram and per-pixel distance.
//

import CoreImage
import CoreMedia
import CoreVideo
import Vision

nonisolated struct SceneSegment: Sendable, Identifiable, Equatable, Codable {
    let index: Int
    let startTime: Double
    let endTime: Double
    let startFrame: Int
    /// Exclusive.
    let endFrame: Int
    /// Score of the cut that started this scene (0 for the first scene).
    let cutScore: Double

    var id: Int { index }
    var duration: Double { endTime - startTime }
}

nonisolated struct SceneCutConfig: Sendable, Equatable {
    /// A cut score must exceed this regardless of recent history.
    var absoluteFloor = 0.35
    /// ...and exceed this multiple of the rolling median score.
    var medianMultiplier = 3.0
    var medianWindow = 30
    /// Minimum seconds between cuts.
    var minSceneLength = 0.5
    /// Reject candidates whose Vision feature prints are nearly identical (flashes, fast pans).
    var confirmWithVision = true
    /// Measured on synthetic footage: ~0.001 between frames of one shot, ~0.3 across a cut.
    var featurePrintThreshold: Float = 0.05
}

/// Per-frame summary used for comparisons.
nonisolated struct FrameSignature: Sendable {
    static let width = 64
    static let height = 36

    let pixels: [OKLab]
    let histogram: OKLabHistogram

    init(pixels: [OKLab]) {
        self.pixels = pixels
        self.histogram = OKLabHistogram(pixels: pixels)
    }

    /// 0.5 · histogram L1 distance + 0.5 · mean OKLab ΔE / 0.25. Black-to-white is ≈ 1.0 on the second term's scale ×4,
    /// so a hard cut between unrelated images lands well above 0.35.
    func cutScore(from previous: FrameSignature) -> Double {
        let histogramTerm = Double(histogram.l1Distance(to: previous.histogram))
        let pixelTerm = Double(OKLabMath.meanDeltaE(pixels, previous.pixels)) / 0.25
        return 0.5 * histogramTerm + 0.5 * pixelTerm
    }
}

/// Decides which scores are cuts using an adaptive threshold. Pure, so it is easy to test.
nonisolated struct CutDecider: Sendable {
    let config: SceneCutConfig
    private var recent: [Double] = []
    private var lastCutTime = -Double.infinity

    init(config: SceneCutConfig) { self.config = config }

    mutating func isCut(score: Double, time: Double) -> Bool {
        let threshold = max(config.absoluteFloor, config.medianMultiplier * median(recent))
        let isCut = score > threshold && time - lastCutTime >= config.minSceneLength
        recent.append(score)
        if recent.count > config.medianWindow { recent.removeFirst() }
        if isCut { lastCutTime = time }
        return isCut
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

actor SceneCutDetector {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    struct Cut: Sendable {
        let frame: Int
        let time: Double
        let score: Double
    }

    /// Analyzes a movie and returns its scenes in order.
    func analyze(
        url: URL,
        config: SceneCutConfig = SceneCutConfig(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SceneSegment] {
        let source = try await FrameSource.open(url: url)
        var decider = CutDecider(config: config)
        var previous: (frame: VideoFrame, signature: FrameSignature)?
        var cuts: [Cut] = []
        var firstTime = 0.0
        var lastTime = 0.0
        var frameCount = 0

        while let frame = try await source.next() {
            try Task.checkCancellation()
            let signature = makeSignature(frame.pixelBuffer)
            if let previous {
                let score = signature.cutScore(from: previous.signature)
                if decider.isCut(score: score, time: frame.seconds) {
                    let confirmed = try await confirm(config, previous.frame, frame)
                    if confirmed { cuts.append(Cut(frame: frame.index, time: frame.seconds, score: score)) }
                }
            } else {
                firstTime = frame.seconds
            }
            previous = (frame, signature)
            lastTime = frame.seconds
            frameCount = frame.index + 1
            if frame.index % 15 == 0, source.duration > 0 { progress?(min(frame.seconds / source.duration, 1)) }
        }
        progress?(1)

        let endTime = lastTime + 1 / source.frameRate
        return Self.scenes(from: cuts, firstTime: firstTime, endTime: endTime, frameCount: frameCount)
    }

    static func scenes(from cuts: [Cut], firstTime: Double, endTime: Double, frameCount: Int) -> [SceneSegment] {
        guard frameCount > 0 else { return [] }
        var boundaries = [Cut(frame: 0, time: firstTime, score: 0)] + cuts
        boundaries.append(Cut(frame: frameCount, time: endTime, score: 0))
        return (0..<boundaries.count - 1).map { i in
            SceneSegment(
                index: i, startTime: boundaries[i].time, endTime: boundaries[i + 1].time,
                startFrame: boundaries[i].frame, endFrame: boundaries[i + 1].frame, cutScore: boundaries[i].score
            )
        }
    }

    private func makeSignature(_ pixelBuffer: CVPixelBuffer) -> FrameSignature {
        let w = FrameSignature.width, h = FrameSignature.height
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleY = Double(h) / image.extent.height
        let scaleX = Double(w) / image.extent.width
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scaleY,
            kCIInputAspectRatioKey: scaleX / scaleY,
        ])
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGB)
        let pixels = bytes.withUnsafeBytes { OKLabMath.convert(rgba: $0, width: w, height: h, bytesPerRow: w * 4) }
        return FrameSignature(pixels: pixels)
    }

    private func confirm(_ config: SceneCutConfig, _ before: VideoFrame, _ after: VideoFrame) async throws -> Bool {
        guard config.confirmWithVision else { return true }
        let a = try await GenerateImageFeaturePrintRequest().perform(on: before.pixelBuffer)
        let b = try await GenerateImageFeaturePrintRequest().perform(on: after.pixelBuffer)
        return Float(try a.distance(to: b)) >= config.featurePrintThreshold
    }
}
