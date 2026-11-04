import AppKit
import SwiftUI

/// A click target with a pointing-hand cursor, laid over a SwiftUI view.
///
/// SwiftUI's `.pointerStyle(.link)` keeps the hand after its view is taken out
/// from under a still pointer (a click that opens another conversation, a
/// scroll), so the hand stayed over the whole conversation until the pointer
/// crossed another view. This AppKit view owns its tracking area, so it puts
/// the arrow back as soon as the pointer leaves it or it leaves the window.
/// Lay it over a `Button` with the same action and hide it from accessibility:
/// the button stays the control for VoiceOver and the keyboard.
struct PointingHandClickArea: NSViewRepresentable {
    let help: String?
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ClickView) {
        view.action = action
        view.toolTip = help
    }

    final class ClickView: NSView {
        var action: () -> Void = {}
        private var isPressed = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            isPressed = true
        }

        override func mouseUp(with event: NSEvent) {
            defer { isPressed = false }
            guard isPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                return
            }
            action()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Leaving the window (the conversation was replaced, or the row
            // scrolled out) while under the pointer: nothing else will put
            // the arrow back until the pointer moves into another view.
            if newWindow == nil, let window, isUnderPointer(in: window) {
                NSCursor.arrow.set()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func isUnderPointer(in window: NSWindow) -> Bool {
            bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
}
