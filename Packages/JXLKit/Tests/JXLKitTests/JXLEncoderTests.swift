import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JXLKit

/// A small RGBA gradient so lossless round-tripping is a meaningful check.
private func makeGradient(width: Int, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x * 255 / max(width - 1, 1))
            pixels[i + 1] = UInt8(y * 255 / max(height - 1, 1))
            pixels[i + 2] = UInt8((x + y) % 256)
        }
    }
    return pixels
}

/// Decodes with ImageIO (an independent decoder) into RGBA8.
private func decodeRGBA(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int, type: String?) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let type = CGImageSourceGetType(source) as String?
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height, type)
}

@Test func losslessRoundTrip() throws {
    let (w, h) = (33, 17)
    let pixels = makeGradient(width: w, height: h)
    let data = try pixels.withUnsafeBytes {
        try JXLEncoder().encode(rgba: $0, width: w, height: h, bytesPerRow: w * 4)
    }
    let decoded = try decodeRGBA(data)
    #expect(decoded.type == UTType.jpegxl.identifier)
    #expect(decoded.width == w && decoded.height == h)
    #expect(decoded.pixels == pixels)
}

@Test func lossyIsCloseAndSmaller() throws {
    let (w, h) = (128, 72)
    let pixels = makeGradient(width: w, height: h)
    let lossless = try pixels.withUnsafeBytes {
        try JXLEncoder().encode(rgba: $0, width: w, height: h, bytesPerRow: w * 4)
    }
    let lossy = try pixels.withUnsafeBytes {
        try JXLEncoder(options: .init(lossless: false, distance: 1.0)).encode(rgba: $0, width: w, height: h, bytesPerRow: w * 4)
    }
    let decoded = try decodeRGBA(lossy)
    let meanError = zip(decoded.pixels, pixels).map { abs(Int($0) - Int($1)) }.reduce(0, +)
    #expect(Double(meanError) / Double(pixels.count) < 4.0)
    #expect(lossy.count < lossless.count)
}

@Test func honorsRowStride() throws {
    let (w, h, stride) = (8, 4, 48)   // 16 bytes of padding per row
    var padded = [UInt8](repeating: 0xAB, count: stride * h)
    for y in 0..<h { for x in 0..<w {
        let i = y * stride + x * 4
        padded[i] = 10; padded[i + 1] = 20; padded[i + 2] = 30; padded[i + 3] = 255
    } }
    let data = try padded.withUnsafeBytes { try JXLEncoder().encode(rgba: $0, width: w, height: h, bytesPerRow: stride) }
    let decoded = try decodeRGBA(data)
    #expect(decoded.pixels.chunks(of: 4).allSatisfy { $0 == [10, 20, 30, 255] })
}

@Test func rejectsBadInput() {
    let bytes = [UInt8](repeating: 0, count: 16)
    #expect(throws: JXLError.invalidDimensions) {
        try bytes.withUnsafeBytes { try JXLEncoder().encode(rgba: $0, width: 0, height: 1, bytesPerRow: 0) }
    }
    #expect(throws: JXLError.bufferTooSmall) {
        try bytes.withUnsafeBytes { try JXLEncoder().encode(rgba: $0, width: 8, height: 8, bytesPerRow: 32) }
    }
}

private extension Array where Element == UInt8 {
    func chunks(of size: Int) -> [[UInt8]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
