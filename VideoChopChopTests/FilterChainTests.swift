//
//  FilterChainTests.swift
//  VideoChopChopTests
//

import CoreImage
import Testing
@testable import VideoChopChop

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Renders to RGBA8; row 0 of the result is the TOP of the image.
private func render(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: sRGB)
    return bytes
}

private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> (r: Int, g: Int, b: Int) {
    let i = (y * width + x) * 4
    return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
}

private func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 16) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: sRGB)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}

/// Top half red, bottom half blue (in display orientation).
private func twoTone(size: Int = 32) -> CIImage {
    let half = size / 2
    let top = solid(1, 0, 0, size: size).cropped(to: CGRect(x: 0, y: half, width: size, height: half))
    let bottom = solid(0, 0, 1, size: size)
    return top.composited(over: bottom).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}

struct FilterChainTests {
    @Test func emptyChainIsIdentity() {
        let out = render(FilterChain().apply(to: solid(0.8, 0.2, 0.4)), width: 16, height: 16)
        let p = pixel(out, x: 8, y: 8, width: 16)
        #expect(abs(p.r - 204) <= 2 && abs(p.g - 51) <= 2 && abs(p.b - 102) <= 2)
    }

    @Test func oklabKernelLoads() {
        #expect(CustomKernels.oklabTweak != nil)
    }

    @Test func oklabTweakWithNeutralSettingsKeepsColor() {
        let chain = FilterChain(steps: [.oklabTweak(saturation: 1, lightness: 1)])
        let p = pixel(render(chain.apply(to: solid(0.8, 0.2, 0.4)), width: 16, height: 16), x: 8, y: 8, width: 16)
        #expect(abs(p.r - 204) <= 3 && abs(p.g - 51) <= 3 && abs(p.b - 102) <= 3)
    }

    @Test func oklabZeroSaturationGivesGray() {
        let chain = FilterChain(steps: [.oklabTweak(saturation: 0, lightness: 1)])
        let p = pixel(render(chain.apply(to: solid(0.9, 0.1, 0.1)), width: 16, height: 16), x: 8, y: 8, width: 16)
        #expect(abs(p.r - p.g) <= 2 && abs(p.g - p.b) <= 2)
    }

    @Test func oklabLightnessDarkens() {
        let chain = FilterChain(steps: [.oklabTweak(saturation: 1, lightness: 0.5)])
        let before = pixel(render(solid(0.6, 0.6, 0.6), width: 16, height: 16), x: 8, y: 8, width: 16)
        let after = pixel(render(chain.apply(to: solid(0.6, 0.6, 0.6)), width: 16, height: 16), x: 8, y: 8, width: 16)
        #expect(after.r < before.r - 40)
    }

    @Test func coreImageStepsRun() {
        let chain = FilterChain(steps: [
            .colorControls(saturation: 0, brightness: 0, contrast: 1),
            .posterize(levels: 4),
            .gaussianBlur(radius: 2),
        ])
        let out = chain.apply(to: twoTone())
        #expect(out.extent == twoTone().extent)
        let p = pixel(render(out, width: 32, height: 32), x: 16, y: 4, width: 32)
        #expect(abs(p.r - p.g) <= 2 && abs(p.g - p.b) <= 2)
    }

    @Test func mpsBlurKeepsOrientation() {
        let out = FilterChain(steps: [.mpsGaussianBlur(sigma: 1)]).apply(to: twoTone())
        let bytes = render(out, width: 32, height: 32)
        let top = pixel(bytes, x: 16, y: 2, width: 32)
        let bottom = pixel(bytes, x: 16, y: 29, width: 32)
        #expect(top.r > 200 && top.b < 60)
        #expect(bottom.b > 200 && bottom.r < 60)
    }

    @Test func mpsSobelFindsTheEdge() {
        let out = FilterChain(steps: [.mpsSobel]).apply(to: twoTone())
        let bytes = render(out, width: 32, height: 32)
        let atEdge = pixel(bytes, x: 16, y: 16, width: 32)
        let flat = pixel(bytes, x: 16, y: 4, width: 32)
        #expect(atEdge.r + atEdge.g + atEdge.b > flat.r + flat.g + flat.b + 60)
    }
}
