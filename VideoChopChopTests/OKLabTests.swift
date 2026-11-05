//
//  OKLabTests.swift
//  VideoChopChopTests
//

import Testing
@testable import VideoChopChop

struct OKLabTests {
    @Test func whiteAndBlack() {
        let white = OKLabMath.fromSRGB8(r: 255, g: 255, b: 255)
        #expect(abs(white.l - 1) < 1e-3)
        #expect(abs(white.a) < 1e-3 && abs(white.b) < 1e-3)

        let black = OKLabMath.fromSRGB8(r: 0, g: 0, b: 0)
        #expect(abs(black.l) < 1e-6)
        #expect(white.distance(to: black) > 0.99 && white.distance(to: black) < 1.01)
    }

    @Test func sRGBRedMatchesReference() {
        let red = OKLabMath.fromSRGB8(r: 255, g: 0, b: 0)
        #expect(abs(red.l - 0.628) < 1e-3)
        #expect(abs(red.a - 0.225) < 1e-3)
        #expect(abs(red.b - 0.126) < 1e-3)
    }

    @Test func convertHonorsRowStride() {
        // 2x1 image with 4 bytes of row padding: one white and one black pixel.
        let bytes: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255, 9, 9, 9, 9]
        let pixels = bytes.withUnsafeBytes {
            OKLabMath.convert(rgba: $0, width: 2, height: 1, bytesPerRow: 12)
        }
        #expect(pixels.count == 2)
        #expect(pixels[0].l > 0.99 && pixels[1].l < 0.01)
    }

    @Test func meanDeltaE() {
        let black = OKLabMath.fromSRGB8(r: 0, g: 0, b: 0)
        let white = OKLabMath.fromSRGB8(r: 255, g: 255, b: 255)
        #expect(OKLabMath.meanDeltaE([black, white], [black, white]) == 0)
        let mean = OKLabMath.meanDeltaE([black, black], [black, white])
        #expect(abs(mean - 0.5) < 0.01)
    }

    @Test func histogramNormalizedAndDistance() {
        let black = OKLabMath.fromSRGB8(r: 0, g: 0, b: 0)
        let white = OKLabMath.fromSRGB8(r: 255, g: 255, b: 255)
        let blackHist = OKLabHistogram(pixels: [OKLab](repeating: black, count: 10))
        let whiteHist = OKLabHistogram(pixels: [OKLab](repeating: white, count: 10))
        #expect(abs(blackHist.bins.reduce(0, +) - 1) < 1e-5)
        #expect(blackHist.l1Distance(to: blackHist) == 0)
        #expect(abs(blackHist.l1Distance(to: whiteHist) - 2) < 1e-5)
    }
}
