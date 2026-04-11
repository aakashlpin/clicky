import CoreGraphics

/// A user-drawn highlight region on a single display, captured during
/// push-to-talk so it can be composited onto that display's screenshot
/// before the JPEG is sent to Claude. The rect is in AppKit display-local
/// points (bottom-left origin), matching NSScreen.frame and NSEvent.mouseLocation.
struct FocusRectangle: Equatable {
    let displayID: CGDirectDisplayID
    let rectInDisplayPoints: CGRect
}
