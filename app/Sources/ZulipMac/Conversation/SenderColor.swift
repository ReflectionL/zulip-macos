import SwiftUI

/// Gives each sender's name a steady color, as Element does, so a busy
/// conversation can be scanned by who is speaking. System colors keep the
/// names legible in light and dark appearance.
enum SenderColor {
    static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    /// The palette slot of a sender; the same person always gets the same one.
    static func index(for senderID: Int64) -> Int {
        Int(senderID.magnitude % UInt64(palette.count))
    }

    static func color(for senderID: Int64) -> Color {
        palette[index(for: senderID)]
    }
}
