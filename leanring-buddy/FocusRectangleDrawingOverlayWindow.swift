//
//  FocusRectangleDrawingOverlayWindow.swift
//  leanring-buddy
//
//  Per-screen drawing overlay window that lets the user click-drag while
//  holding push-to-talk to describe a focus region on top of whatever they
//  are looking at. This window is a *sibling* of `OverlayWindow` — same
//  screen-saver level, same all-spaces collection behavior, same per-screen
//  lifecycle — but unlike `OverlayWindow` it can flip into an "armed"
//  state where it absorbs mouse events instead of passing them through,
//  so the user's drag can be captured and rendered as a live warm-yellow
//  rectangle.
//
//  One `FocusRectangleDrawingOverlayWindow` is instantiated per NSScreen by
//  `FocusRectangleDrawingOverlayManager`. The manager coordinates which
//  screen "owns" the in-progress drag so that mousing onto a second monitor
//  during a drag cannot spawn a duplicate rectangle on another screen.
//

import AppKit
import SwiftUI

// MARK: - Window

/// NSPanel subclass that hosts the focus-rectangle drawing UI on a single
/// screen. Cannot become key or main, so clicking inside it (e.g. at the
/// start of a drag) never steals key-window state from the user's target
/// app — this mirrors the `NonKeyingBorderlessPanel` pattern used by the
/// delegation log sidebar for the same reason.
final class FocusRectangleDrawingOverlayWindow: NSPanel {
    /// The drawing state object bound to this overlay window's SwiftUI
    /// content view. Owned here so the window's mouse-event capture view
    /// can write into it directly during a drag.
    let focusRectangleDrawingState: FocusRectangleDrawingState

    /// The NSScreen this overlay window is anchored to. Retained so the
    /// manager can map drag results back to a `CGDirectDisplayID` without
    /// needing to walk `NSScreen.screens` on every mouseUp.
    let associatedScreen: NSScreen

    /// AppKit view that captures mouseDown/mouseDragged/mouseUp while the
    /// overlay is armed. Layered above the SwiftUI content so it intercepts
    /// clicks that would otherwise hit the (non-interactive) SwiftUI view.
    private let focusRectangleMouseEventCaptureView: FocusRectangleMouseEventCaptureView

    /// SwiftUI hosting view that renders the live drag rectangle. Sits
    /// underneath the mouse-event capture view inside a shared container.
    private let focusRectangleDrawingHostingView: NSHostingView<FocusRectangleDrawingView>

    init(screen: NSScreen) {
        self.associatedScreen = screen
        let focusRectangleDrawingState = FocusRectangleDrawingState()
        self.focusRectangleDrawingState = focusRectangleDrawingState
        self.focusRectangleDrawingHostingView = NSHostingView(
            rootView: FocusRectangleDrawingView(
                focusRectangleDrawingState: focusRectangleDrawingState
            )
        )
        self.focusRectangleMouseEventCaptureView = FocusRectangleMouseEventCaptureView()

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Visual + window-manager setup. Matches OverlayWindow's screen-saver
        // level so the drawn rectangle appears above the dock, the menu bar,
        // and any popups the user's target app is showing.
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Start in passive (click-through) mode. The manager flips this to
        // `false` via `setDrawingArmed(true)` when push-to-talk begins.
        self.ignoresMouseEvents = true

        // Pin the panel to the associated screen's frame so window-local
        // (0, 0) == the screen's bottom-left in AppKit coordinates. This
        // is the invariant that lets the manager treat the drag points as
        // display-local directly.
        self.setFrame(screen.frame, display: true)
        if let screenMatchingThisFrame = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenMatchingThisFrame.frame.origin)
        }

        // Container NSView that holds both the SwiftUI hosting view
        // (bottom, rendering) and the AppKit mouse-event capture view
        // (top, interception). The SwiftUI view does NOT receive mouse
        // events directly — NSHostingView forwards through by default only
        // when the SwiftUI content opts into hit testing, and we need the
        // reliable AppKit override pattern anyway so we can tell the
        // manager exactly which window owns the drag.
        let contentContainerView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        contentContainerView.autoresizingMask = [.width, .height]
        contentContainerView.wantsLayer = true

        focusRectangleDrawingHostingView.frame = contentContainerView.bounds
        focusRectangleDrawingHostingView.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(focusRectangleDrawingHostingView)

        focusRectangleMouseEventCaptureView.frame = contentContainerView.bounds
        focusRectangleMouseEventCaptureView.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(focusRectangleMouseEventCaptureView)

        self.contentView = contentContainerView
    }

    // MARK: - Key / main window behavior

    // Never become key or main. Clicking inside the overlay should not
    // steal focus from the user's target app; we only want the raw drag
    // coordinates. This mirrors the delegation log sidebar's approach.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Armed / disarmed state

    /// Flips the overlay between passive (click-through) and armed
    /// (mouse-capturing) modes. While disarmed, clicks fall through to
    /// whatever app is underneath the overlay; while armed, the embedded
    /// mouse-event capture view absorbs them so the user can draw a focus
    /// region.
    func setDrawingArmed(
        _ shouldArmDrawing: Bool,
        onMouseDown handleMouseDown: @escaping (FocusRectangleDrawingOverlayWindow, CGPoint) -> Void,
        onMouseDragged handleMouseDragged: @escaping (FocusRectangleDrawingOverlayWindow, CGPoint) -> Void,
        onMouseUp handleMouseUp: @escaping (FocusRectangleDrawingOverlayWindow, CGPoint) -> Void
    ) {
        self.ignoresMouseEvents = !shouldArmDrawing
        focusRectangleDrawingState.isDrawingArmed = shouldArmDrawing

        if shouldArmDrawing {
            // Wire the capture view's closures so every mouse event is
            // routed back to the manager with a reference to *this* window.
            // The manager uses the window reference to (a) identify the
            // owning screen and (b) disarm every other overlay during a
            // drag so a dual-monitor setup can only produce one rectangle.
            focusRectangleMouseEventCaptureView.onMouseDownInWindowCoordinates = { [weak self] mouseDownPointInWindowCoordinates in
                guard let self else { return }
                handleMouseDown(self, mouseDownPointInWindowCoordinates)
            }
            focusRectangleMouseEventCaptureView.onMouseDraggedInWindowCoordinates = { [weak self] mouseDraggedPointInWindowCoordinates in
                guard let self else { return }
                handleMouseDragged(self, mouseDraggedPointInWindowCoordinates)
            }
            focusRectangleMouseEventCaptureView.onMouseUpInWindowCoordinates = { [weak self] mouseUpPointInWindowCoordinates in
                guard let self else { return }
                handleMouseUp(self, mouseUpPointInWindowCoordinates)
            }
        } else {
            // Clear closures so a stray mouse event (shouldn't happen since
            // `ignoresMouseEvents` is true, but belt-and-braces) can't
            // re-enter a stale handler from a previous arm cycle.
            focusRectangleMouseEventCaptureView.onMouseDownInWindowCoordinates = nil
            focusRectangleMouseEventCaptureView.onMouseDraggedInWindowCoordinates = nil
            focusRectangleMouseEventCaptureView.onMouseUpInWindowCoordinates = nil
            // Also clear any in-progress drag state so the SwiftUI view
            // stops rendering its live rectangle immediately.
            focusRectangleDrawingState.currentDragStartInWindowCoordinates = nil
            focusRectangleDrawingState.currentDragCurrentInWindowCoordinates = nil
        }
    }

    /// Clears the in-progress drag state without changing the armed flag.
    /// Used by the manager when it wants to cancel a drag (e.g. the user
    /// moved off-screen or released push-to-talk mid-drag) without fully
    /// tearing down the overlay.
    func clearInProgressDragState() {
        focusRectangleDrawingState.currentDragStartInWindowCoordinates = nil
        focusRectangleDrawingState.currentDragCurrentInWindowCoordinates = nil
    }
}

// MARK: - Mouse event capture view

/// Tiny NSView subclass whose only job is to absorb mouse events and
/// forward window-local CGPoints to closures owned by the drawing overlay
/// window. We need an AppKit view for this because NSHostingView does not
/// reliably receive `mouseDown` events for a SwiftUI subtree that is just
/// showing `Color.clear` and `Rectangle().stroke(...)`.
///
/// All points delivered to the closures are converted to **SwiftUI-style
/// top-left-origin coordinates** relative to this view's bounds, so the
/// drawing overlay window can hand them straight to the SwiftUI drawing
/// state without additional flipping.
final class FocusRectangleMouseEventCaptureView: NSView {
    /// Invoked when the user presses the primary mouse button inside the
    /// overlay while drawing is armed. Point is in SwiftUI-local coords
    /// (top-left origin).
    var onMouseDownInWindowCoordinates: ((CGPoint) -> Void)?

    /// Invoked on every drag frame while the primary mouse button is held.
    /// Point is in SwiftUI-local coords (top-left origin).
    var onMouseDraggedInWindowCoordinates: ((CGPoint) -> Void)?

    /// Invoked when the user releases the primary mouse button. Point is
    /// in SwiftUI-local coords (top-left origin).
    var onMouseUpInWindowCoordinates: ((CGPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A clear layer-backed view so we can intercept mouse events without
        // painting anything and without obstructing the SwiftUI drawing
        // layer underneath us.
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("FocusRectangleMouseEventCaptureView does not support NSCoder init")
    }

    // Accept the very first click even though the host panel is a
    // non-activating panel that never becomes key. Without this, the first
    // mouseDown of a drag would be swallowed as an "activate-only" event.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    // MARK: - Mouse event overrides

    override func mouseDown(with event: NSEvent) {
        let mouseDownPointInSwiftUILocalCoordinates = convertEventLocationToSwiftUILocalCoordinates(event: event)
        onMouseDownInWindowCoordinates?(mouseDownPointInSwiftUILocalCoordinates)
    }

    override func mouseDragged(with event: NSEvent) {
        let mouseDraggedPointInSwiftUILocalCoordinates = convertEventLocationToSwiftUILocalCoordinates(event: event)
        onMouseDraggedInWindowCoordinates?(mouseDraggedPointInSwiftUILocalCoordinates)
    }

    override func mouseUp(with event: NSEvent) {
        let mouseUpPointInSwiftUILocalCoordinates = convertEventLocationToSwiftUILocalCoordinates(event: event)
        onMouseUpInWindowCoordinates?(mouseUpPointInSwiftUILocalCoordinates)
    }

    // MARK: - Coordinate conversion

    /// Converts an NSEvent's location (AppKit window-local coords, bottom-left
    /// origin) into this view's bounds coordinates flipped to SwiftUI-style
    /// top-left origin. The drawing overlay window covers the entire screen
    /// and the mouse-capture view matches the window's content view bounds,
    /// so converting the event to view-local space only needs `convert(_:from:)`
    /// with `nil` (window coords) followed by a Y-flip against `bounds.height`.
    private func convertEventLocationToSwiftUILocalCoordinates(event: NSEvent) -> CGPoint {
        let eventPointInAppKitViewCoordinates = self.convert(event.locationInWindow, from: nil)
        let eventPointInSwiftUIViewCoordinates = CGPoint(
            x: eventPointInAppKitViewCoordinates.x,
            y: self.bounds.height - eventPointInAppKitViewCoordinates.y
        )
        return eventPointInSwiftUIViewCoordinates
    }
}
