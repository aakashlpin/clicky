//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ImageIO
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayID: CGDirectDisplayID
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. By default this
    /// captures every connected display, but when `restrictToDisplayID`
    /// is supplied only that single display is captured — the PTT path
    /// uses this to send Claude just the screen the user cares about
    /// (either the one they drew a focus rectangle on, or the one the
    /// cursor is currently sitting on) instead of a composite of every
    /// connected monitor. If the requested `restrictToDisplayID` can't
    /// be found in the current display list (e.g. monitor unplugged
    /// mid-session), the function falls back to the cursor's display.
    static func captureAllScreensAsJPEG(
        highlightFocusRectangle: FocusRectangle? = nil,
        restrictToDisplayID: CGDirectDisplayID? = nil
    ) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplaysBeforeRestriction = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        // If the caller requested a single display, filter down to just
        // that one. If the requested display isn't present (e.g. the
        // user unplugged a monitor between push-to-talk press and
        // capture), fall back to the cursor's display — which, because
        // of the sort above, is always the first entry.
        let sortedDisplays: [SCDisplay] = {
            guard let restrictToDisplayID else {
                return sortedDisplaysBeforeRestriction
            }
            if let matchingDisplay = sortedDisplaysBeforeRestriction.first(where: { $0.displayID == restrictToDisplayID }) {
                return [matchingDisplay]
            }
            if let cursorDisplayFallback = sortedDisplaysBeforeRestriction.first {
                print("⚠️ Requested display \(restrictToDisplayID) not found in current display list — falling back to cursor display \(cursorDisplayFallback.displayID)")
                return [cursorDisplayFallback]
            }
            return []
        }()

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            // If the caller supplied a focus rectangle that belongs to THIS display,
            // stamp it onto the JPEG before appending. Our overlay windows are filtered
            // out of the live screenshot (see SCContentFilter above), so the yellow
            // border must be drawn into the image bytes after capture.
            let jpegDataToUse: Data
            if let highlightFocusRectangle,
               highlightFocusRectangle.displayID == display.displayID {
                jpegDataToUse = compositeFocusRectangleIfPossible(
                    originalJpegData: jpegData,
                    focusRectangleInDisplayPoints: highlightFocusRectangle.rectInDisplayPoints,
                    displayFrame: displayFrame,
                    screenshotWidthInPixels: configuration.width,
                    screenshotHeightInPixels: configuration.height
                )
            } else {
                jpegDataToUse = jpegData
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegDataToUse,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayID: display.displayID,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Persists the provided captures to a caller-specified Application Support
    /// subdirectory and returns the written file URLs in the same order.
    static func persistCapturesToDisk(
        _ captures: [CompanionScreenCapture],
        intoSubdirectoryNamed subdirectoryName: String
    ) throws -> [URL] {
        let applicationSupportDirectoryURL = try requiredApplicationSupportDirectoryURL()
        let capturesDirectoryURL = applicationSupportDirectoryURL
            .appendingPathComponent("Flowee/Multica Attachments", isDirectory: true)
            .appendingPathComponent(subdirectoryName, isDirectory: true)

        try FileManager.default.createDirectory(
            at: capturesDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var persistedCaptureFileURLs: [URL] = []
        persistedCaptureFileURLs.reserveCapacity(captures.count)

        for (captureIndex, capture) in captures.enumerated() {
            let captureFilenameSlug = sanitizedCaptureFilenameSlug(from: capture.label)
            let captureFilename = "screen-\(String(format: "%02d", captureIndex))-\(captureFilenameSlug).jpg"
            let captureFileURL = capturesDirectoryURL.appendingPathComponent(captureFilename, isDirectory: false)
            try capture.imageData.write(to: captureFileURL)
            persistedCaptureFileURLs.append(captureFileURL)
        }

        return persistedCaptureFileURLs
    }

    /// Stamps a warm-yellow border for the user's focus rectangle onto the captured
    /// JPEG for a single display. The input rect is in AppKit display-local points
    /// (bottom-left origin, matching NSEvent.mouseLocation); the output is re-encoded
    /// JPEG data in the same pixel dimensions as the original. On ANY failure (clamp
    /// to empty, decode error, context error, re-encode error) we log a single
    /// diagnostic line and return the original JPEG so the user still gets a response.
    private static func compositeFocusRectangleIfPossible(
        originalJpegData: Data,
        focusRectangleInDisplayPoints: CGRect,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> Data {
        // Clamp the incoming rect to the display's bounds so a runaway drag
        // off-screen can't produce negative or out-of-bounds coordinates.
        let displayBoundsInDisplayPoints = CGRect(origin: .zero, size: displayFrame.size)
        let clampedFocusRectangleInDisplayPoints = focusRectangleInDisplayPoints
            .intersection(displayBoundsInDisplayPoints)

        if clampedFocusRectangleInDisplayPoints.isNull
            || clampedFocusRectangleInDisplayPoints.isEmpty
            || clampedFocusRectangleInDisplayPoints.width <= 0
            || clampedFocusRectangleInDisplayPoints.height <= 0 {
            print("⚠️ Focus rectangle compositing skipped: clamped rect is empty or zero-size")
            return originalJpegData
        }

        // Decode the JPEG back into a CGImage via Core Graphics' native path.
        // We deliberately do NOT route through NSBitmapImageRep(data:).cgImage
        // here: that accessor has had orientation quirks across macOS versions
        // when decoding a JPEG that was itself encoded by NSBitmapImageRep
        // (which is exactly what the outer loop does at the top of
        // captureAllScreensAsJPEG before handing the bytes to this function).
        // In those cases the resulting CGImage's pixel rows can be bottom-up,
        // and when it's drawn into our flipped CGContext the two flips
        // compound into a vertically inverted output. CGImageSource is
        // deterministic and always returns a natively top-down CGImage.
        guard let cgImageSource = CGImageSourceCreateWithData(originalJpegData as CFData, nil),
              let decodedCGImage = CGImageSourceCreateImageAtIndex(cgImageSource, 0, nil) else {
            print("⚠️ Focus rectangle compositing skipped: failed to decode JPEG back to CGImage")
            return originalJpegData
        }

        let sRGBColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfoRawValue: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let compositingContext = CGContext(
            data: nil,
            width: screenshotWidthInPixels,
            height: screenshotHeightInPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGBColorSpace,
            bitmapInfo: bitmapInfoRawValue
        ) else {
            print("⚠️ Focus rectangle compositing skipped: failed to create CGContext")
            return originalJpegData
        }

        // CGBitmapContext defaults to bottom-left origin, which matches
        // AppKit's coordinate system. We draw the decoded CGImage without
        // any transform — draw(in:) renders it right-side-up in the user
        // coordinate system, and the bottom-left origin produces correctly
        // oriented pixel rows in the buffer. A previous version applied
        // translateBy(0,H)+scaleBy(1,-1) to flip into top-left-origin
        // space, but that inverted the drawn image (draw() maps the image's
        // visual bottom to rect.minY, and the flip moved minY to the top
        // of the buffer, producing a vertically inverted output).
        let fullScreenshotRectInPixels = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(screenshotWidthInPixels),
            height: CGFloat(screenshotHeightInPixels)
        )
        compositingContext.draw(decodedCGImage, in: fullScreenshotRectInPixels)

        // The focus rectangle is in AppKit display-local points (bottom-left
        // origin), which matches the CGContext's default bottom-left origin.
        // We only need to scale from display points to screenshot pixels —
        // no Y-axis flip is needed.
        let displayWidthInDisplayPoints = displayFrame.width
        let displayHeightInDisplayPoints = displayFrame.height

        guard displayWidthInDisplayPoints > 0, displayHeightInDisplayPoints > 0 else {
            print("⚠️ Focus rectangle compositing skipped: display frame has zero size")
            return originalJpegData
        }

        let screenshotToDisplayScaleX = CGFloat(screenshotWidthInPixels) / displayWidthInDisplayPoints
        let screenshotToDisplayScaleY = CGFloat(screenshotHeightInPixels) / displayHeightInDisplayPoints

        let focusRectangleInScreenshotPixels = CGRect(
            x: clampedFocusRectangleInDisplayPoints.origin.x * screenshotToDisplayScaleX,
            y: clampedFocusRectangleInDisplayPoints.origin.y * screenshotToDisplayScaleY,
            width: clampedFocusRectangleInDisplayPoints.width * screenshotToDisplayScaleX,
            height: clampedFocusRectangleInDisplayPoints.height * screenshotToDisplayScaleY
        )

        // Warm bright yellow — more readable against real UI than pure #FFFF00,
        // which tends to vibrate uncomfortably against light backgrounds.
        let warmYellowStrokeColor = CGColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
        compositingContext.setLineWidth(6)
        compositingContext.setStrokeColor(warmYellowStrokeColor)
        compositingContext.stroke(focusRectangleInScreenshotPixels)

        guard let compositedCGImage = compositingContext.makeImage() else {
            print("⚠️ Focus rectangle compositing skipped: makeImage() returned nil")
            return originalJpegData
        }

        // Encode via Core Graphics' native JPEG encoder (CGImageDestination).
        // We deliberately do NOT route through NSBitmapImageRep(cgImage:) here
        // because that wrapper reads the CGImage's backing store with its own
        // assumptions about pixel row order. CGImageDestinationAddImage
        // preserves the CGImage's pixel data directly and produces a correct
        // JPEG regardless of the source context's configuration.
        let jpegDestinationData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(
            jpegDestinationData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            print("⚠️ Focus rectangle compositing skipped: failed to create CGImageDestination for JPEG")
            return originalJpegData
        }

        let jpegCompressionQualityForCompositedImage: Double = 0.8
        let imageDestinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegCompressionQualityForCompositedImage
        ]
        CGImageDestinationAddImage(
            imageDestination,
            compositedCGImage,
            imageDestinationOptions as CFDictionary
        )

        guard CGImageDestinationFinalize(imageDestination) else {
            print("⚠️ Focus rectangle compositing skipped: CGImageDestinationFinalize failed")
            return originalJpegData
        }

        return jpegDestinationData as Data
    }

    private static func requiredApplicationSupportDirectoryURL() throws -> URL {
        guard let applicationSupportDirectoryURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Application Support directory is unavailable"]
            )
        }

        return applicationSupportDirectoryURL
    }

    private static func sanitizedCaptureFilenameSlug(from captureLabel: String) -> String {
        let lowercaseCaptureLabel = captureLabel.lowercased()
        let nonAlphanumericCharacters = CharacterSet.alphanumerics.inverted
        let slugComponents = lowercaseCaptureLabel
            .components(separatedBy: nonAlphanumericCharacters)
            .filter { !$0.isEmpty }
        let joinedSlug = slugComponents.joined(separator: "-")
        let trimmedSlug = joinedSlug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if trimmedSlug.isEmpty {
            return "capture"
        }

        return String(trimmedSlug.prefix(40))
    }
}
