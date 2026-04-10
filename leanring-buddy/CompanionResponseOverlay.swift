//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Minimal cursor-following status chip for markdown transcript exports.
//  It stays fully click-through and only communicates state transitions:
//  generating, ready to copy via keyboard shortcut, and copied.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    enum MarkdownTranscriptStatus {
        case hidden
        case generating
        case readyToCopy
        case copied
        case failed
    }

    @Published var markdownTranscriptStatus: MarkdownTranscriptStatus = .hidden
    @Published var statusTitleText: String = ""
    @Published var statusDetailText: String = ""
}

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var cursorTrackingTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?

    private let cursorOffsetX: CGFloat = 20
    private let cursorOffsetY: CGFloat = 4
    private let overlayWidth: CGFloat = 190

    func showGeneratingMarkdownTranscriptStatus() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.markdownTranscriptStatus = .generating
        overlayViewModel.statusTitleText = "Creating transcript"
        overlayViewModel.statusDetailText = "Reading screenshot..."
        showOverlay()
    }

    func showReadyToCopyMarkdownTranscriptStatus() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.markdownTranscriptStatus = .readyToCopy
        overlayViewModel.statusTitleText = "Transcript ready"
        overlayViewModel.statusDetailText = "Press ^⌥C to copy"
        showOverlay()
    }

    func showCopiedMarkdownTranscriptStatus() {
        overlayViewModel.markdownTranscriptStatus = .copied
        overlayViewModel.statusTitleText = "Transcript copied"
        overlayViewModel.statusDetailText = "Markdown copied to clipboard"
        showOverlay()

        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.hideMarkdownTranscriptOverlay()
        }
        autoHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: hideWorkItem)
    }

    func showMarkdownTranscriptErrorStatus() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.markdownTranscriptStatus = .failed
        overlayViewModel.statusTitleText = "Transcript failed"
        overlayViewModel.statusDetailText = "Try again"
        showOverlay()

        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.hideMarkdownTranscriptOverlay()
        }
        autoHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: hideWorkItem)
    }

    func hideMarkdownTranscriptOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        stopCursorTracking()
        overlayViewModel.markdownTranscriptStatus = .hidden
        overlayViewModel.statusTitleText = ""
        overlayViewModel.statusDetailText = ""
        overlayPanel?.orderOut(nil)
    }

    private func showOverlay() {
        createOverlayPanelIfNeeded()
        startCursorTracking()
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
        repositionPanelNearCursor()
    }

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayWidth, height: 54)
        let responseOverlayPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        responseOverlayPanel.ignoresMouseEvents = true
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: CompanionResponseOverlayView(viewModel: overlayViewModel)
        )
        hostingView.frame = initialFrame
        responseOverlayPanel.contentView = hostingView

        overlayPanel = responseOverlayPanel
    }

    private func startCursorTracking() {
        stopCursorTracking()
        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanelNearCursor()
            }
        }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
    }

    private func repositionPanelNearCursor() {
        guard let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        if let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            let visibleFrame = currentScreen.visibleFrame

            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }
}

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel

    var body: some View {
        if viewModel.markdownTranscriptStatus != .hidden {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.statusTitleText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(viewModel.statusDetailText)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(width: 190, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.8)
                    )
            )
        }
    }
}
