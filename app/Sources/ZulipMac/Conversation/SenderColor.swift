import SwiftUI

/// Gives each sender's name a steady color, as Element does, so a busy
/// conversation can be scanned by who is speaking. Eight hues spread around
/// the color wheel at one lightness and a muted saturation, so no name shouts
/// louder than the message under it; each has a light and a dark value that
/// keeps at least 4.5:1 contrast on the canvas.
enum SenderColor {
    /// Light and dark sRGB values: terracotta, ochre, olive, green, teal, blue,
    /// violet, rose.
    static let hexPairs: [(light: UInt32, dark: UInt32)] = [
        (0xB1595B, 0xDC8B8B),
        (0xA66324, 0xD19461),
        (0x7D7609, 0xA9A456),
        (0x298352, 0x69B183),
        (0x008087, 0x40B1B7),
        (0x2B77B0, 0x68A6DA),
        (0x7B67B2, 0xA998DD),
        (0xA65987, 0xD28BB3),
    ]

    static let palette: [Color] = hexPairs.map { Color.dynamic(light: $0.light, dark: $0.dark) }

    /// The palette slot of a sender; the same person always gets the same one.
    static func index(for senderID: Int64) -> Int {
        Int(senderID.magnitude % UInt64(palette.count))
    }

    static func color(for senderID: Int64) -> Color {
        palette[index(for: senderID)]
    }
}
