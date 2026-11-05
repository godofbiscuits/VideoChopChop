//
//  FrameSource.swift
//  VideoChopChop
//
//  Pull-based video decoding: callers ask for the next frame, so decoding
//  never runs ahead of analysis or export.
//

import AVFoundation
import CoreMedia
import CoreVideo

/// A decoded video frame. The pixel buffer is never mutated after delivery, so sharing it is safe.
nonisolated struct VideoFrame: @unchecked Sendable {
    let index: Int
    let time: CMTime
    let pixelBuffer: CVPixelBuffer

    var seconds: Double { time.seconds }
}

nonisolated enum FrameSourceError: Error {
    case noVideoTrack
    case cannotStartReading(String)
}

/// Streams BGRA frames from the first video track of a movie file.
actor FrameSource {
    nonisolated let duration: Double
    nonisolated let frameRate: Double
    /// Pixel size of the stored frames (before `preferredTransform`).
    nonisolated let size: CGSize
    nonisolated let preferredTransform: CGAffineTransform

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var nextIndex = 0

    static func open(url: URL) async throws -> FrameSource {
        try await FrameSource(url: url)
    }

    // The asset, track, reader and output are all non-Sendable, so everything is created inside this initializer.
    private init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameSourceError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let (fps, size, preferredTransform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
        let frameRate = fps > 0 ? Double(fps) : 30

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw FrameSourceError.cannotStartReading(reader.error?.localizedDescription ?? "unknown error")
        }
        self.reader = reader
        self.output = output
        self.duration = duration
        self.frameRate = frameRate
        self.size = size
        self.preferredTransform = preferredTransform
    }

    /// Returns the next frame, or nil at the end of the video.
    func next() throws -> VideoFrame? {
        while let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            defer { nextIndex += 1 }
            return VideoFrame(index: nextIndex, time: CMSampleBufferGetPresentationTimeStamp(sample), pixelBuffer: pixelBuffer)
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return nil
    }
}
