import Foundation
import SwiftUI

/// Evens out the colors Zulip users pick for their channels. The hue is the
/// user's choice and is kept; the lightness is fixed and the saturation capped,
/// so pale pastels stay visible on the sidebar (about 3:1) and no dot jumps out
/// brighter than the others.
enum ChannelColor {
    static let lightLightness = 0.62
    static let darkLightness = 0.74
    static let maximumChroma = 0.12

    /// The server's `#rrggbb` color; a mid gray when it cannot be read.
    static func rgb(fromHex hex: String) -> UInt32 {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt32(sanitized, radix: 16) else {
            return 0x808080
        }
        return value & 0xFFFFFF
    }

    /// The same hue at the lightness for dark or light appearance, with its
    /// chroma capped.
    static func normalized(_ rgb: UInt32, dark: Bool) -> UInt32 {
        let color = OKLCHColor(rgb: rgb)
        return OKLCHColor(
            lightness: dark ? darkLightness : lightLightness,
            chroma: min(color.chroma, maximumChroma),
            hue: color.hue
        ).rgb
    }

    static func color(hex: String) -> Color {
        let value = rgb(fromHex: hex)
        return Color.dynamic(
            light: normalized(value, dark: false),
            dark: normalized(value, dark: true)
        )
    }
}

/// A color in the OKLCH space: perceptual lightness (0–1), chroma, and hue in
/// degrees. Conversions follow Björn Ottosson's OKLab definition.
struct OKLCHColor: Equatable {
    var lightness: Double
    var chroma: Double
    var hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    /// From an sRGB value such as `0x4553D0`.
    init(rgb: UInt32) {
        func linear(_ component: UInt32) -> Double {
            let value = Double(component & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = linear(rgb >> 16)
        let green = linear(rgb >> 8)
        let blue = linear(rgb)

        let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)

        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let degrees = atan2(b, a) * 180 / .pi

        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        chroma = (a * a + b * b).squareRoot()
        hue = degrees < 0 ? degrees + 360 : degrees
    }

    /// The nearest sRGB value; components outside the gamut are clipped.
    var rgb: UInt32 {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let lRoot = lightness + 0.3963377774 * a + 0.2158037573 * b
        let mRoot = lightness - 0.1055613458 * a - 0.0638541728 * b
        let sRoot = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot

        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        func encoded(_ linear: Double) -> UInt32 {
            let clipped = min(max(linear, 0), 1)
            let value = clipped <= 0.0031308
                ? 12.92 * clipped
                : 1.055 * pow(clipped, 1 / 2.4) - 0.055
            return UInt32((value * 255).rounded())
        }
        return (encoded(red) << 16) | (encoded(green) << 8) | encoded(blue)
    }
}
