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
    // The receiver replaces the pixel-buffer adaptor; its append suspends until the input can take more frames.
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    do { try writer.start() } catch { throw TestVideoError.writerFailed(error.localizedDescription) }
    writer.startSession(atSourceTime: .zero)

    var frameIndex: Int64 = 0
    for segment in segments {
        for i in 0..<segment.frames {
            let frame = try makeTestFrame(segment: segment, index: i, width: width, height: height)
            try await receiver.append(frame, with: CMTime(value: frameIndex, timescale: fps))
            frameIndex += 1
        }
    }
    receiver.finish()
    await writer.finishWriting()
    guard writer.status == .completed else { throw TestVideoError.writerFailed(writer.error?.localizedDescription ?? "finish") }
    return url
}

/// One frame of a segment as a read-only pixel buffer. Built in its own function so the buffer is handed to the
/// writer as a fresh value (nothing else keeps a reference to it).
private func makeTestFrame(segment: TestSegment, index i: Int, width: Int, height: Int) throws -> CVReadOnlyPixelBuffer {
    var created: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created)
    guard let buffer = created else { throw TestVideoError.writerFailed("no buffer") }
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
    return CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
}
