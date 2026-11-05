//
//  FilterSettings.swift
//  VideoChopChop
//
//  Inspector state (toggles and slider values) that is turned into a FilterChain.
//

import Foundation

struct FilterSettings: Equatable {
    var blurEnabled = false
    var blurRadius = 6.0

    var edgesEnabled = false
    var edgeIntensity = 4.0

    var colorEnabled = false
    var saturation = 1.0
    var brightness = 0.0
    var contrast = 1.0

    var posterizeEnabled = false
    var posterizeLevels = 6.0

    /// Custom Metal kernel working in OKLab.
    var oklabEnabled = false
    var oklabSaturation = 1.3
    var oklabLightness = 1.0

    var mpsBlurEnabled = false
    var mpsSigma = 4.0

    var mpsSobelEnabled = false

    var chain: FilterChain {
        var steps: [FilterChain.Step] = []
        if colorEnabled { steps.append(.colorControls(saturation: saturation, brightness: brightness, contrast: contrast)) }
        if oklabEnabled { steps.append(.oklabTweak(saturation: oklabSaturation, lightness: oklabLightness)) }
        if blurEnabled { steps.append(.gaussianBlur(radius: blurRadius)) }
        if mpsBlurEnabled { steps.append(.mpsGaussianBlur(sigma: mpsSigma)) }
        if posterizeEnabled { steps.append(.posterize(levels: posterizeLevels)) }
        if edgesEnabled { steps.append(.edges(intensity: edgeIntensity)) }
        if mpsSobelEnabled { steps.append(.mpsSobel) }
        return FilterChain(steps: steps)
    }
}
