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
        case multicaIssueFiled
    }

    @Published var markdownTranscriptStatus: MarkdownTranscriptStatus = .hidden
    @Published var statusTitleText: String = ""
    @Published var statusDetailText: String = ""
    @Published var usesCompactSingleLineLayout: Bool = false
}

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var cursorTrackingTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?

    private let cursorOffsetX: CGFloat = 20
    private let cursorOffsetY: CGFloat = 4
    private let markdownTranscriptOverlaySize = CGSize(width: 190, height: 54)
    private let multicaIssueFiledOverlaySize = CGSize(width: 280, height: 36)

    func showGeneratingMarkdownTranscriptStatus() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.markdownTranscriptStatus = .generating
        overlayViewModel.statusTitleText = "Creating transcript"
        overlayViewModel.statusDetailText = "Reading screenshot..."
        overlayViewModel.usesCompactSingleLineLayout = false
        showOverlay()
    }

    func showReadyToCopyMarkdownTranscriptStatus() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.markdownTranscriptStatus = .readyToCopy
        overlayViewModel.statusTitleText = "Transcript ready"
        overlayViewModel.statusDetailText = "Press ^⌥C to copy"
        overlayViewModel.usesCompactSingleLineLayout = false
        showOverlay()
    }

    func showCopiedMarkdownTranscriptStatus() {
        overlayViewModel.markdownTranscriptStatus = .copied
        overlayViewModel.statusTitleText = "Transcript copied"
        overlayViewModel.statusDetailText = "Markdown copied to clipboard"
        overlayViewModel.usesCompactSingleLineLayout = false
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
        overlayViewModel.usesCompactSingleLineLayout = false
        showOverlay()

        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.hideMarkdownTranscriptOverlay()
        }
        autoHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: hideWorkItem)
    }

    func showMulticaIssueFiledChip(issueIdentifier: String, assigneeAgentName: String) {
        autoHideWorkItem?.cancel()
        overlayViewModel.markdownTranscriptStatus = .multicaIssueFiled
        overlayViewModel.statusTitleText = "Filed \(issueIdentifier) → \(assigneeAgentName)"
        overlayViewModel.statusDetailText = ""
        overlayViewModel.usesCompactSingleLineLayout = true
        showOverlay(fadesIn: true)

        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.hideOverlay(fadesOut: true)
        }
        autoHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: hideWorkItem)
    }

    func hideMarkdownTranscriptOverlay() {
        hideOverlay()
    }

    private func showOverlay(fadesIn: Bool = false) {
        createOverlayPanelIfNeeded()
        updateOverlayPanelSize()
        startCursorTracking()
        if fadesIn {
            overlayPanel?.alphaValue = 0
            overlayPanel?.orderFrontRegardless()
            animateOverlayAlpha(to: 1, duration: DS.Animation.normal)
        } else {
            overlayPanel?.alphaValue = 1
        }
        overlayPanel?.orderFrontRegardless()
        repositionPanelNearCursor()
    }

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(origin: .zero, size: markdownTranscriptOverlaySize)
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

    private func updateOverlayPanelSize() {
        guard let overlayPanel, let hostingView = overlayPanel.contentView else { return }

        let overlaySize = currentOverlaySize
        let overlayFrame = NSRect(origin: overlayPanel.frame.origin, size: overlaySize)
        overlayPanel.setFrame(overlayFrame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: overlaySize)
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

    private func hideOverlay(fadesOut: Bool = false) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        guard let overlayPanel else {
            resetOverlayState()
            return
        }

        if fadesOut {
            animateOverlayAlpha(to: 0, duration: DS.Animation.normal) { [weak self] in
                guard let self else { return }
                self.stopCursorTracking()
                overlayPanel.orderOut(nil)
                self.resetOverlayState()
            }
            return
        }

        stopCursorTracking()
        overlayPanel.orderOut(nil)
        resetOverlayState()
    }

    private func animateOverlayAlpha(to alphaValue: CGFloat, duration: Double, completion: (() -> Void)? = nil) {
        guard let overlayPanel else {
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = duration
            animationContext.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlayPanel.animator().alphaValue = alphaValue
        } completionHandler: {
            completion?()
        }
    }

    private func resetOverlayState() {
        overlayViewModel.markdownTranscriptStatus = .hidden
        overlayViewModel.statusTitleText = ""
        overlayViewModel.statusDetailText = ""
        overlayViewModel.usesCompactSingleLineLayout = false
    }

    private var currentOverlaySize: CGSize {
        overlayViewModel.usesCompactSingleLineLayout ? multicaIssueFiledOverlaySize : markdownTranscriptOverlaySize
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
            Group {
                if viewModel.usesCompactSingleLineLayout {
                    Text(viewModel.statusTitleText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.statusTitleText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)

                        Text(viewModel.statusDetailText)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, viewModel.usesCompactSingleLineLayout ? 7 : 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.8)
                    )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
