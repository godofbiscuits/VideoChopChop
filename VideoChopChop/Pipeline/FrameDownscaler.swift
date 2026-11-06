//
//  FrameDownscaler.swift
//  VideoChopChop
//
//  Shrinks a decoded frame to the scene-cut signature size on the GPU.
//
//  EXCEPTION to the scaling / box-blur rule: this deliberately uses Metal Performance Shaders'
//  Lanczos scaler rather than a box (area-average) filter or the Core Image scaler. Measured on
//  1080p frames in Release, the Core Image downscale cost 6–8 ms per frame (99% of the scan's
//  analysis time) against about 1.9 ms for MPS Lanczos (0.65 ms on the GPU), with cut scores
//  within 0.008 of the old ones (the cut threshold is 0.35). A custom box kernel was a further
//  0.8 ms faster but needs its own Metal library, so it was not worth it.
//
//  The source is sampled through an sRGB-decoding view, so the filter runs on linear light and
//  the result is ready for the sRGB → linear → OKLab conversion (no averaging in sRGB).
//

import CoreVideo
import Metal
import MetalPerformanceShaders

nonisolated final class FrameDownscaler {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let scaler: MPSImageLanczosScale
    private let output: any MTLTexture
    let width: Int
    let height: Int

    /// Nil when this Mac has no usable Metal device; callers fall back to Core Image.
    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        description.usage = [.shaderRead, .shaderWrite]
        description.storageMode = .shared
        guard let output = device.makeTexture(descriptor: description) else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        let scaler = MPSImageLanczosScale(device: device)
        scaler.edgeMode = .clamp   // the default treats pixels beyond the frame as black and darkens the border
        self.scaler = scaler
        self.output = output
        self.width = width
        self.height = height
    }

    /// The frame shrunk to `width` × `height` as linear-light RGBA floats (row-major, 4 floats per pixel),
    /// or nil when the frame can't be wrapped as a texture or the GPU work fails.
    func linearRGBA(of pixelBuffer: CVPixelBuffer) async -> [Float]? {
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm_srgb,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &wrapped
        ) == kCVReturnSuccess, let wrapped, let source = CVMetalTextureGetTexture(wrapped),
              let commands = queue.makeCommandBuffer() else { return nil }

        scaler.encode(commandBuffer: commands, sourceTexture: source, destinationTexture: output)
        await withCheckedContinuation { continuation in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }
        guard commands.status == .completed else { return nil }

        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return values
    }
}
