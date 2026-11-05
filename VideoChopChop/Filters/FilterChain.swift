//
//  FilterChain.swift
//  VideoChopChop
//
//  One description of image processing that drives the live preview (AVVideoComposition),
//  the exported frames, and the tests.
//

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalPerformanceShaders

nonisolated struct FilterChain: Sendable, Equatable, Codable {
    nonisolated enum Step: Sendable, Equatable, Codable {
        /// Core Image built-ins.
        case gaussianBlur(radius: Double)
        case edges(intensity: Double)
        case colorControls(saturation: Double, brightness: Double, contrast: Double)
        case posterize(levels: Double)
        /// Custom Metal CIColorKernel (Kernels.ci.metal).
        case oklabTweak(saturation: Double, lightness: Double)
        /// Metal Performance Shaders.
        case mpsGaussianBlur(sigma: Double)
        case mpsSobel
    }

    var steps: [Step] = []
    var isEmpty: Bool { steps.isEmpty }

    func apply(to image: CIImage) -> CIImage {
        steps.reduce(image) { $1.apply(to: $0) }
    }
}

nonisolated extension FilterChain.Step {
    func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        switch self {
        case .gaussianBlur(let radius):
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(radius)
            return filter.outputImage?.cropped(to: extent) ?? image
        case .edges(let intensity):
            let filter = CIFilter.edges()
            filter.inputImage = image
            filter.intensity = Float(intensity)
            return filter.outputImage?.cropped(to: extent) ?? image
        case .colorControls(let saturation, let brightness, let contrast):
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(saturation)
            filter.brightness = Float(brightness)
            filter.contrast = Float(contrast)
            return filter.outputImage ?? image
        case .posterize(let levels):
            let filter = CIFilter.colorPosterize()
            filter.inputImage = image
            filter.levels = Float(levels)
            return filter.outputImage ?? image
        case .oklabTweak(let saturation, let lightness):
            guard let kernel = CustomKernels.oklabTweak else { return image }
            return kernel.apply(extent: extent, arguments: [image, Float(saturation), Float(lightness)]) ?? image
        case .mpsGaussianBlur(let sigma):
            return MPSPass.shared?.gaussianBlur(image, sigma: Float(sigma)) ?? image
        case .mpsSobel:
            return MPSPass.shared?.sobel(image) ?? image
        }
    }
}

/// Custom Core Image kernels, precompiled from Kernels.ci.metal into the app's default.metallib.
///
/// Requires the target build settings `MTL_COMPILER_FLAGS = -fcikernel` and `MTLLINKER_FLAGS = -cikernel`
/// (set through Metal.xcconfig); without them the metallib can't be loaded as Core Image kernels.
nonisolated enum CustomKernels {
    private final class BundleToken {}

    // CIKernel is immutable after creation and safe to share across threads.
    nonisolated(unsafe) static let oklabTweak: CIColorKernel? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CIColorKernel(functionName: "oklabTweak", fromMetalLibraryData: data)
    }()
}

/// Runs Metal Performance Shaders image kernels on Core Image images (render → MPS → wrap back).
nonisolated final class MPSPass: @unchecked Sendable {
    nonisolated(unsafe) static let shared = MPSPass()

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let context: CIContext
    private let lock = NSLock()
    /// Core Image's working color space; textures hold linear-light values.
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.context = CIContext(mtlCommandQueue: queue)
    }

    func gaussianBlur(_ image: CIImage, sigma: Float) -> CIImage {
        run(image) { MPSImageGaussianBlur(device: $0, sigma: sigma) }
    }

    func sobel(_ image: CIImage) -> CIImage {
        run(image) { MPSImageSobel(device: $0) }
    }

    private func run(_ image: CIImage, kernel makeKernel: (any MTLDevice) -> MPSUnaryImageKernel) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return image }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(extent.width), height: Int(extent.height), mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let input = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return image }

        // One command buffer at a time keeps GPU memory use bounded when frames are processed in parallel.
        lock.lock()
        defer { lock.unlock() }
        context.render(image, to: input, commandBuffer: commandBuffer, bounds: extent, colorSpace: Self.linear)
        makeKernel(device).encode(commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: output)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Core Image already accounts for the texture's top-left origin when it wraps the texture
        // (verified by a pixel-orientation test), so no extra flip is applied here.
        guard let result = CIImage(mtlTexture: output, options: [.colorSpace: Self.linear]) else { return image }
        return result.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}

/// Builds the preview composition that applies a filter chain to every frame of an asset.
nonisolated enum PreviewComposition {
    static func make(asset: AVAsset, chain: FilterChain) async throws -> AVVideoComposition {
        try await AVVideoComposition(applyingFiltersTo: asset) { params in
            AVCIImageFilteringResult(resultImage: chain.apply(to: params.sourceImage), ciContext: nil)
        }
    }
}
