//
//  FocusRectangleDrawingView.swift
//  leanring-buddy
//
//  SwiftUI view that renders the live focus-rectangle drag feedback for the
//  per-screen drawing overlay window. The view observes a shared
//  `FocusRectangleDrawingState` that is updated by the AppKit mouse-event
//  capture view living inside the same overlay window. When the user is
//  actively dragging to describe a region, the view renders an empty
//  warm-yellow rounded rectangle spanning the current drag bounds.
//

import Combine
import SwiftUI

/// Shared observable state that drives the focus-rectangle drawing overlay.
/// The AppKit mouse-event capture view writes drag coordinates into this
/// object on every mouseDown/mouseDragged/mouseUp, and the SwiftUI view
/// re-renders the live rectangle from those coordinates.
///
/// All coordinates stored here are in the drawing overlay window's local
/// coordinate space (top-left origin SwiftUI space, because NSHostingView
/// converts AppKit's bottom-left origin to SwiftUI's top-left origin for us
/// when we feed the mouse capture view's frame-local points directly into
/// SwiftUI. We adopt the convention that `FocusRectangleDrawingOverlayWindow`
/// always feeds *SwiftUI-style* (top-left origin) coordinates into this
/// state object, and translates the AppKit event points itself).
@MainActor
final class FocusRectangleDrawingState: ObservableObject {
    /// When true, the drawing overlay is actively accepting mouse events.
    /// When false, the SwiftUI view renders nothing and clicks fall through.
    @Published var isDrawingArmed: Bool = false

    /// The point where the current drag started, in SwiftUI-local coordinates
    /// (top-left origin, matching the drawing overlay window's content view).
    /// Nil when no drag is in progress.
    @Published var currentDragStartInWindowCoordinates: CGPoint?

    /// The most recent drag point, in SwiftUI-local coordinates
    /// (top-left origin). Nil when no drag is in progress.
    @Published var currentDragCurrentInWindowCoordinates: CGPoint?

    /// Opt-in flag to render a faint full-screen veil while drawing is armed
    /// but before the user has started dragging. Off for v1 — reserved for
    /// a possible future iteration if users have trouble understanding that
    /// the draw mode is live.
    @Published var shouldShowArmedVeil: Bool = false
}

/// Pure SwiftUI view hosted inside `FocusRectangleDrawingOverlayWindow`. It
/// observes the shared drawing state and renders either nothing (when not
/// armed, or armed-but-not-dragging with the veil disabled) or a warm
/// yellow empty rounded rectangle (when actively dragging).
struct FocusRectangleDrawingView: View {
    @ObservedObject var focusRectangleDrawingState: FocusRectangleDrawingState

    /// Warm yellow that matches the screenshot compositor's stroke color.
    /// Kept as an inline literal because `DS.Colors` has no equivalent token.
    /// The compositor uses the same RGB so the user sees the same color
    /// while drawing as Claude ultimately sees in the composited JPEG.
    private let focusRectangleStrokeColor = Color(red: 1.0, green: 0.85, blue: 0.0)

    /// Stroke width, in points, of the focus rectangle's border. The rendered
    /// rectangle is inset by half this width so the stroke sits entirely
    /// inside the conceptual drag bounds (StrokeStyle draws centered on the
    /// path, and without an inset the outer half would be clipped).
    private let focusRectangleStrokeWidthInPoints: CGFloat = 6.0

    /// Corner radius for the drawn focus rectangle. Kept modest so the
    /// user perceives a sharp region selection, not a pill.
    private let focusRectangleCornerRadiusInPoints: CGFloat = 6.0

    var body: some View {
        ZStack {
            // Transparent background. Clicks fall through to the user's app
            // when the overlay window has `ignoresMouseEvents = true` (i.e.
            // not armed). When armed, the AppKit mouse-event capture view
            // layered above this SwiftUI content will absorb clicks instead.
            Color.clear

            // Optional faint veil that hints at "drawing mode active" while
            // the user has armed the overlay but has not yet started a drag.
            // Off by default; opt-in via `shouldShowArmedVeil`.
            if focusRectangleDrawingState.isDrawingArmed
                && focusRectangleDrawingState.shouldShowArmedVeil
                && focusRectangleDrawingState.currentDragStartInWindowCoordinates == nil {
                Color.black.opacity(0.04)
                    .ignoresSafeArea()
            }

            // Live focus rectangle during an active drag.
            if focusRectangleDrawingState.isDrawingArmed,
               let currentDragStartInWindowCoordinates = focusRectangleDrawingState.currentDragStartInWindowCoordinates,
               let currentDragCurrentInWindowCoordinates = focusRectangleDrawingState.currentDragCurrentInWindowCoordinates {
                let liveDragRectangleInWindowCoordinates = buildRectangle(
                    fromStartPoint: currentDragStartInWindowCoordinates,
                    toCurrentPoint: currentDragCurrentInWindowCoordinates
                )

                // Inset by half the stroke width so the full 6pt border is
                // visible inside the conceptual drag bounds. Without the
                // inset, SwiftUI would center the stroke on the rectangle's
                // edge and the outer half would be clipped at screen edges.
                let strokeInsetInPoints = focusRectangleStrokeWidthInPoints / 2.0
                let insetLiveDragRectangleInWindowCoordinates = liveDragRectangleInWindowCoordinates
                    .insetBy(dx: strokeInsetInPoints, dy: strokeInsetInPoints)

                RoundedRectangle(
                    cornerRadius: focusRectangleCornerRadiusInPoints,
                    style: .continuous
                )
                .stroke(
                    focusRectangleStrokeColor,
                    style: StrokeStyle(
                        lineWidth: focusRectangleStrokeWidthInPoints,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(
                    width: max(0, insetLiveDragRectangleInWindowCoordinates.width),
                    height: max(0, insetLiveDragRectangleInWindowCoordinates.height)
                )
                .shadow(color: .yellow.opacity(0.5), radius: 8)
                .position(
                    x: insetLiveDragRectangleInWindowCoordinates.midX,
                    y: insetLiveDragRectangleInWindowCoordinates.midY
                )
                .allowsHitTesting(false)
            }
        }
    }

    /// Builds a CGRect from an arbitrary pair of drag points. The drag may
    /// originate at any corner and move in any direction, so we normalize
    /// to a rect with positive width and height.
    private func buildRectangle(
        fromStartPoint startPointInWindowCoordinates: CGPoint,
        toCurrentPoint currentPointInWindowCoordinates: CGPoint
    ) -> CGRect {
        let originXInWindowCoordinates = min(startPointInWindowCoordinates.x, currentPointInWindowCoordinates.x)
        let originYInWindowCoordinates = min(startPointInWindowCoordinates.y, currentPointInWindowCoordinates.y)
        let widthInPoints = abs(currentPointInWindowCoordinates.x - startPointInWindowCoordinates.x)
        let heightInPoints = abs(currentPointInWindowCoordinates.y - startPointInWindowCoordinates.y)
        return CGRect(
            x: originXInWindowCoordinates,
            y: originYInWindowCoordinates,
            width: widthInPoints,
            height: heightInPoints
        )
    }
}
