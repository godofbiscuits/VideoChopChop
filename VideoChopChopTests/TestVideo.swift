//
//  TestVideo.swift
//  VideoChopChopTests
//
//  Generates small H.264 movies with known content for pipeline tests.
//

import AVFoundation
import CoreVideo

struct TestSegment {
    var frames: Int
    /// Returns (r, g, b) for a pixel given its x position (0...1) and progress through the segment (0...1).
    var color: @Sendable (_ x: Double, _ t: Double) -> (UInt8, UInt8, UInt8)

    static func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, frames: Int) -> TestSegment {
        TestSegment(frames: frames) { _, _ in (r, g, b) }
    }

    static func horizontalGradient(frames: Int) -> TestSegment {
        TestSegment(frames: frames) { x, _ in
            let v = UInt8(x * 255)
            return (v, UInt8(255 - Int(v)), 128)
        }
    }

    /// Fades uniformly from `from` to `to` gray levels over the segment.
    static func grayRamp(from: Double, to: Double, frames: Int) -> TestSegment {
        TestSegment(frames: frames) { _, t in
            let v = UInt8((from + (to - from) * t) * 255)
            return (v, v, v)
        }
    }
}

enum TestVideoError: Error { case writerFailed(String) }

func makeTestVideo(segments: [TestSegment], width: Int = 320, height: Int = 180, fps: Int32 = 30) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw TestVideoError.writerFailed(writer.error?.localizedDescription ?? "start") }
    writer.startSession(atSourceTime: .zero)

    var frameIndex: Int64 = 0
    for segment in segments {
        for i in 0..<segment.frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let pool = adaptor.pixelBufferPool else { throw TestVideoError.writerFailed("no pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw TestVideoError.writerFailed("no buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let t = Double(i) / Double(max(segment.frames - 1, 1))
            for x in 0..<width {
                let (r, g, b) = segment.color(Double(x) / Double(width - 1), t)
                for y in 0..<height {
                    let p = base + y * stride + x * 4
                    p[0] = b; p[1] = g; p[2] = r; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
            frameIndex += 1
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw TestVideoError.writerFailed(writer.error?.localizedDescription ?? "finish") }
    return url
}
