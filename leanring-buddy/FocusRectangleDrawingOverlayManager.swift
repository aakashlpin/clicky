//
//  FocusRectangleDrawingOverlayManager.swift
//  leanring-buddy
//
//  Owns the per-screen `FocusRectangleDrawingOverlayWindow` instances and
//  coordinates their lifecycle. The manager sits between `CompanionManager`
//  (which arms/disarms drawing when push-to-talk starts/stops) and the
//  low-level drag-capture overlays (which actually paint the rectangle and
//  capture mouse events). The only published product of a drag is a
//  `FocusRectangle` — a shared value type the screenshot compositor consumes
//  in a separate worktree.
//
//  The core invariant the manager enforces is: at most one screen may own
//  an in-progress drag at any given time. When the user presses down on
//  screen A, every other overlay is immediately disarmed so that moving
//  onto screen B mid-drag cannot spawn a parallel rectangle. When the drag
//  ends (or is canceled), the manager re-arms every overlay as long as
//  drawing is still globally armed.
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class FocusRectangleDrawingOverlayManager: ObservableObject {
    /// The most recent completed focus rectangle, if any. Published so
    /// `CompanionManager` (or any other SwiftUI consumer) can observe it
    /// and kick off the screenshot compositor when the drag ends. Reset
    /// to `nil` via `resetFocusRectangle()` after the orchestrator has
    /// fully consumed the rectangle at the end of a response cycle.
    @Published private(set) var currentFocusRectangle: FocusRectangle?

    /// Called on every completed drag (after the in-progress state has
    /// been cleared and the overlays have been re-armed or disarmed).
    /// Fires regardless of whether the drag produced a rectangle above
    /// the minimum threshold. `CompanionManager` uses this to release a
    /// transcript that was queued pending drag completion — the
    /// "fires on whichever comes later" (keyboard vs mouse) behavior
    /// that makes release-ordering of push-to-talk + drag forgiving.
    var onAnyDragCompleted: (() -> Void)?

    /// True while a drag is in progress (between mouseDown and mouseUp
    /// on any overlay). Used by `CompanionManager` to decide whether to
    /// fire the transcript immediately on finalization or hold it until
    /// the drag resolves.
    var isDragInProgress: Bool {
        overlayWindowOwningInProgressDrag != nil
    }

    /// Minimum drag extent (in points) that counts as a "real" rectangle.
    /// Anything smaller is treated as an accidental click and discarded.
    /// 6pt matches the stroke width of the drawn border so sub-stroke-width
    /// drags never accidentally emit a degenerate rectangle.
    private let minimumDragExtentInPoints: CGFloat = 6.0

    /// Per-screen drawing overlay windows. Created lazily in
    /// `showDrawingOverlays(onScreens:)` and torn down in
    /// `hideDrawingOverlays()`.
    private var focusRectangleDrawingOverlayWindows: [FocusRectangleDrawingOverlayWindow] = []

    /// Global "drawing should be armed" latch. True while the user is
    /// holding push-to-talk and the orchestrator has told us to accept
    /// drag input. Used so that finishing a drag on one screen re-arms
    /// every overlay (we only disarm others *during* a drag to enforce
    /// single-screen ownership, then restore them when the drag ends).
    private var isGlobalDrawingArmLatchOn: Bool = false

    /// Reference to the overlay window that currently owns the in-progress
    /// drag, if any. Non-nil only between mouseDown and mouseUp on that
    /// window. Used to ignore any stray mouseDragged / mouseUp events that
    /// might arrive from a different window during the drag.
    private weak var overlayWindowOwningInProgressDrag: FocusRectangleDrawingOverlayWindow?

    // MARK: - Public API

    /// Creates one drawing overlay window per supplied screen (if not
    /// already created) and orders them in. Safe to call with an empty
    /// array — the manager is designed to be instantiated eagerly before
    /// any screens are known.
    func showDrawingOverlays(onScreens screens: [NSScreen]) {
        // Tear down any existing overlays first. The drag-capture overlays
        // are cheap to recreate and this guarantees we always match the
        // caller's current screen list exactly (including handling
        // hot-plugged monitors).
        hideDrawingOverlays()

        for screen in screens {
            let focusRectangleDrawingOverlayWindow = FocusRectangleDrawingOverlayWindow(screen: screen)
            focusRectangleDrawingOverlayWindows.append(focusRectangleDrawingOverlayWindow)
            focusRectangleDrawingOverlayWindow.orderFrontRegardless()
        }
    }

    /// Orders every overlay window out and releases them. Also clears the
    /// global arm latch so a subsequent `showDrawingOverlays(...)` starts
    /// in a passive state until the caller explicitly arms drawing again.
    func hideDrawingOverlays() {
        isGlobalDrawingArmLatchOn = false
        overlayWindowOwningInProgressDrag = nil

        for focusRectangleDrawingOverlayWindow in focusRectangleDrawingOverlayWindows {
            focusRectangleDrawingOverlayWindow.orderOut(nil)
            focusRectangleDrawingOverlayWindow.contentView = nil
        }
        focusRectangleDrawingOverlayWindows.removeAll()
    }

    /// Puts every overlay window into mouse-capture mode and clears any
    /// stale completed rectangle. Called by the orchestrator when the
    /// user begins holding push-to-talk and may start drawing a region.
    func armDrawing() {
        isGlobalDrawingArmLatchOn = true
        overlayWindowOwningInProgressDrag = nil
        currentFocusRectangle = nil

        for focusRectangleDrawingOverlayWindow in focusRectangleDrawingOverlayWindows {
            armSpecificDrawingOverlayWindow(focusRectangleDrawingOverlayWindow)
        }
    }

    /// Puts every overlay window back into click-through mode. Called by
    /// the orchestrator when push-to-talk is released (or the session is
    /// otherwise canceled) so the overlays stop consuming mouse events.
    /// Any in-progress drag is discarded silently.
    func disarmDrawing() {
        isGlobalDrawingArmLatchOn = false
        overlayWindowOwningInProgressDrag = nil

        for focusRectangleDrawingOverlayWindow in focusRectangleDrawingOverlayWindows {
            disarmSpecificDrawingOverlayWindow(focusRectangleDrawingOverlayWindow)
        }
    }

    /// Turns off the global drawing arm latch without killing any drag
    /// that is already in progress. If no drag is in progress, this is
    /// equivalent to `disarmDrawing()`. If a drag IS in progress, every
    /// overlay is left in its current state so the in-flight drag can
    /// finish naturally via its existing event pipeline — once the
    /// drag's `mouseUp` lands, `handleMouseUp`'s defer block sees the
    /// latch is off and disarms the originating overlay from there.
    ///
    /// This is what makes "release keyboard a few milliseconds before
    /// the mouse" forgiving: the drag survives the keyboard release and
    /// the rectangle the user drew still gets captured.
    func finishPendingDragThenDisarm() {
        isGlobalDrawingArmLatchOn = false

        if overlayWindowOwningInProgressDrag == nil {
            // No drag in progress — disarm everything immediately, matching
            // the old disarmDrawing semantics for the common case where the
            // user released the keyboard without ever touching the mouse.
            for focusRectangleDrawingOverlayWindow in focusRectangleDrawingOverlayWindows {
                disarmSpecificDrawingOverlayWindow(focusRectangleDrawingOverlayWindow)
            }
        }
        // Otherwise: leave overlays alone. The in-flight drag will finish
        // naturally, its handleMouseUp will commit the rectangle and fire
        // onAnyDragCompleted, and the defer block will disarm the
        // originating overlay (the others were already disarmed at
        // mouseDown to enforce single-screen drag ownership).
    }

    /// Clears the most recent completed focus rectangle. Called by the
    /// orchestrator after the rectangle has been fully consumed by the
    /// screenshot compositor (end of a response cycle).
    func resetFocusRectangle() {
        currentFocusRectangle = nil
    }

    // MARK: - Per-window arm / disarm helpers

    /// Puts a single overlay window into mouse-capture mode and wires its
    /// drag callbacks back to this manager so we can enforce single-screen
    /// ownership during the drag.
    private func armSpecificDrawingOverlayWindow(
        _ focusRectangleDrawingOverlayWindow: FocusRectangleDrawingOverlayWindow
    ) {
        focusRectangleDrawingOverlayWindow.setDrawingArmed(
            true,
            onMouseDown: { [weak self] originatingOverlayWindow, mouseDownPointInSwiftUIWindowCoordinates in
                self?.handleMouseDown(
                    onOverlayWindow: originatingOverlayWindow,
                    atPointInSwiftUIWindowCoordinates: mouseDownPointInSwiftUIWindowCoordinates
                )
            },
            onMouseDragged: { [weak self] originatingOverlayWindow, mouseDraggedPointInSwiftUIWindowCoordinates in
                self?.handleMouseDragged(
                    onOverlayWindow: originatingOverlayWindow,
                    atPointInSwiftUIWindowCoordinates: mouseDraggedPointInSwiftUIWindowCoordinates
                )
            },
            onMouseUp: { [weak self] originatingOverlayWindow, mouseUpPointInSwiftUIWindowCoordinates in
                self?.handleMouseUp(
                    onOverlayWindow: originatingOverlayWindow,
                    atPointInSwiftUIWindowCoordinates: mouseUpPointInSwiftUIWindowCoordinates
                )
            }
        )
    }

    /// Puts a single overlay window into click-through mode. Installs
    /// inert closures because `setDrawingArmed(false, ...)` clears them
    /// anyway; we only need the signature to be satisfied.
    private func disarmSpecificDrawingOverlayWindow(
        _ focusRectangleDrawingOverlayWindow: FocusRectangleDrawingOverlayWindow
    ) {
        focusRectangleDrawingOverlayWindow.setDrawingArmed(
            false,
            onMouseDown: { _, _ in },
            onMouseDragged: { _, _ in },
            onMouseUp: { _, _ in }
        )
    }

    // MARK: - Drag lifecycle

    /// Handles the initial mouseDown for a drag. Records the start point
    /// in the originating overlay's shared drawing state, claims single-
    /// screen ownership of the drag, and disarms every *other* overlay
    /// window so a second monitor cannot spawn a parallel rectangle.
    private func handleMouseDown(
        onOverlayWindow originatingOverlayWindow: FocusRectangleDrawingOverlayWindow,
        atPointInSwiftUIWindowCoordinates mouseDownPointInSwiftUIWindowCoordinates: CGPoint
    ) {
        guard isGlobalDrawingArmLatchOn else { return }

        overlayWindowOwningInProgressDrag = originatingOverlayWindow
        originatingOverlayWindow.focusRectangleDrawingState.currentDragStartInWindowCoordinates = mouseDownPointInSwiftUIWindowCoordinates
        originatingOverlayWindow.focusRectangleDrawingState.currentDragCurrentInWindowCoordinates = mouseDownPointInSwiftUIWindowCoordinates

        // Disarm every other overlay so only the originating screen can
        // produce a rectangle during this drag.
        for otherOverlayWindow in focusRectangleDrawingOverlayWindows where otherOverlayWindow !== originatingOverlayWindow {
            disarmSpecificDrawingOverlayWindow(otherOverlayWindow)
        }
    }

    /// Handles a mouseDragged frame. Updates the live "current" point on
    /// the drag-owning overlay so the SwiftUI view can re-render the
    /// rectangle. Ignores events from any window that isn't the current
    /// drag owner.
    ///
    /// Intentionally does NOT check `isGlobalDrawingArmLatchOn`: once a
    /// drag has started, it is allowed to finish even if the user
    /// released push-to-talk mid-drag, so the rectangle they're drawing
    /// still gets captured. The `overlayWindowOwningInProgressDrag ===`
    /// check is sufficient to reject stray events from other windows.
    private func handleMouseDragged(
        onOverlayWindow originatingOverlayWindow: FocusRectangleDrawingOverlayWindow,
        atPointInSwiftUIWindowCoordinates mouseDraggedPointInSwiftUIWindowCoordinates: CGPoint
    ) {
        guard originatingOverlayWindow === overlayWindowOwningInProgressDrag else { return }

        originatingOverlayWindow.focusRectangleDrawingState.currentDragCurrentInWindowCoordinates = mouseDraggedPointInSwiftUIWindowCoordinates
    }

    /// Handles the mouseUp that ends a drag. If the drag covers at least
    /// `minimumDragExtentInPoints` in either dimension, the manager emits
    /// a `FocusRectangle` on `currentFocusRectangle`; otherwise the drag
    /// is discarded as an accidental click. Either way, every overlay is
    /// re-armed (as long as the global drawing latch is still on) so the
    /// user can start another drag on any screen; if the latch was turned
    /// off mid-drag (push-to-talk released before mouse up), the
    /// originating overlay is disarmed instead.
    ///
    /// Intentionally does NOT check `isGlobalDrawingArmLatchOn`: once a
    /// drag has started, it is allowed to finish even if push-to-talk
    /// was released mid-drag, so the user's rectangle still lands.
    private func handleMouseUp(
        onOverlayWindow originatingOverlayWindow: FocusRectangleDrawingOverlayWindow,
        atPointInSwiftUIWindowCoordinates mouseUpPointInSwiftUIWindowCoordinates: CGPoint
    ) {
        guard originatingOverlayWindow === overlayWindowOwningInProgressDrag else { return }

        defer {
            // Clear the per-overlay drag state so the SwiftUI view stops
            // rendering the live rectangle immediately after we commit.
            originatingOverlayWindow.clearInProgressDragState()
            overlayWindowOwningInProgressDrag = nil

            if isGlobalDrawingArmLatchOn {
                // User is still holding push-to-talk — re-arm every overlay
                // so they can immediately start another drag on any screen.
                for focusRectangleDrawingOverlayWindow in focusRectangleDrawingOverlayWindows {
                    armSpecificDrawingOverlayWindow(focusRectangleDrawingOverlayWindow)
                }
            } else {
                // Push-to-talk was released mid-drag via
                // finishPendingDragThenDisarm(). The drag just finished and
                // there's nothing more to capture, so disarm the originating
                // overlay now (the other overlays were already disarmed at
                // mouseDown to enforce single-screen drag ownership, so we
                // only need to touch this one).
                disarmSpecificDrawingOverlayWindow(originatingOverlayWindow)
            }

            // Notify any listener that a drag has completed, regardless of
            // whether it produced a rectangle above the minimum threshold.
            // CompanionManager uses this to release a transcript that was
            // queued pending drag completion (the "fires on whichever comes
            // later" behavior).
            onAnyDragCompleted?()
        }

        guard let dragStartPointInSwiftUIWindowCoordinates = originatingOverlayWindow
                .focusRectangleDrawingState
                .currentDragStartInWindowCoordinates else {
            return
        }

        let dragExtentInXDirectionInPoints = abs(mouseUpPointInSwiftUIWindowCoordinates.x - dragStartPointInSwiftUIWindowCoordinates.x)
        let dragExtentInYDirectionInPoints = abs(mouseUpPointInSwiftUIWindowCoordinates.y - dragStartPointInSwiftUIWindowCoordinates.y)
        let maximumDragExtentInPoints = max(dragExtentInXDirectionInPoints, dragExtentInYDirectionInPoints)

        // Below the minimum threshold → click-without-drag. Discard and
        // do not emit a rectangle.
        guard maximumDragExtentInPoints >= minimumDragExtentInPoints else {
            return
        }

        guard let finishedFocusRectangle = buildFocusRectangle(
            fromDragStartInSwiftUIWindowCoordinates: dragStartPointInSwiftUIWindowCoordinates,
            toDragEndInSwiftUIWindowCoordinates: mouseUpPointInSwiftUIWindowCoordinates,
            onOverlayWindow: originatingOverlayWindow
        ) else {
            return
        }

        currentFocusRectangle = finishedFocusRectangle
    }

    // MARK: - Rectangle construction

    /// Builds a `FocusRectangle` from a pair of SwiftUI-local drag points
    /// and the overlay window that owns the drag. The drag points live in
    /// the SwiftUI (top-left origin) coordinate space of the overlay
    /// window's content view, so this method flips them back into AppKit
    /// (bottom-left origin) display-local points before constructing the
    /// `FocusRectangle`.
    ///
    /// Because the overlay window covers the entire screen frame exactly
    /// (see `FocusRectangleDrawingOverlayWindow.init(screen:)`), window-
    /// local AppKit coordinates map 1:1 to display-local AppKit
    /// coordinates — the window's origin equals the screen's origin in
    /// both dimensions. This mirrors the `screenFrame` invariant used in
    /// `OverlayWindow.swift` for the blue cursor overlays.
    private func buildFocusRectangle(
        fromDragStartInSwiftUIWindowCoordinates dragStartPointInSwiftUIWindowCoordinates: CGPoint,
        toDragEndInSwiftUIWindowCoordinates dragEndPointInSwiftUIWindowCoordinates: CGPoint,
        onOverlayWindow originatingOverlayWindow: FocusRectangleDrawingOverlayWindow
    ) -> FocusRectangle? {
        // Look up the CGDirectDisplayID for the originating overlay's
        // associated screen. Same pattern as
        // `CompanionScreenCaptureUtility.swift` uses to correlate screens
        // with displays at capture time.
        guard let displayIDForOriginatingScreen = originatingOverlayWindow
                .associatedScreen
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        let overlayWindowContentHeightInPoints = originatingOverlayWindow.associatedScreen.frame.height

        // Flip from SwiftUI top-left origin back to AppKit bottom-left
        // origin. Y' = (screenHeight - Y).
        let dragStartPointInAppKitDisplayLocalCoordinates = CGPoint(
            x: dragStartPointInSwiftUIWindowCoordinates.x,
            y: overlayWindowContentHeightInPoints - dragStartPointInSwiftUIWindowCoordinates.y
        )
        let dragEndPointInAppKitDisplayLocalCoordinates = CGPoint(
            x: dragEndPointInSwiftUIWindowCoordinates.x,
            y: overlayWindowContentHeightInPoints - dragEndPointInSwiftUIWindowCoordinates.y
        )

        // Normalize so the resulting rect always has positive width/height
        // regardless of which corner the user started dragging from.
        let normalizedOriginXInDisplayPoints = min(
            dragStartPointInAppKitDisplayLocalCoordinates.x,
            dragEndPointInAppKitDisplayLocalCoordinates.x
        )
        let normalizedOriginYInDisplayPoints = min(
            dragStartPointInAppKitDisplayLocalCoordinates.y,
            dragEndPointInAppKitDisplayLocalCoordinates.y
        )
        let normalizedWidthInDisplayPoints = abs(
            dragEndPointInAppKitDisplayLocalCoordinates.x - dragStartPointInAppKitDisplayLocalCoordinates.x
        )
        let normalizedHeightInDisplayPoints = abs(
            dragEndPointInAppKitDisplayLocalCoordinates.y - dragStartPointInAppKitDisplayLocalCoordinates.y
        )

        let normalizedFocusRectangleInDisplayPoints = CGRect(
            x: normalizedOriginXInDisplayPoints,
            y: normalizedOriginYInDisplayPoints,
            width: normalizedWidthInDisplayPoints,
            height: normalizedHeightInDisplayPoints
        )

        return FocusRectangle(
            displayID: displayIDForOriginatingScreen,
            rectInDisplayPoints: normalizedFocusRectangleInDisplayPoints
        )
    }
}
