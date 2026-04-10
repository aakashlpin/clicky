//
//  DelegationRepoPickerOverlay.swift
//  leanring-buddy
//
//  Cursor-adjacent interactive picker for choosing which allowed workspace
//  should receive a delegated coding task. Modeled after the markdown
//  transcript chip, but keyboard-navigable and click-selectable.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DelegationRepoPickerOverlayManager: NSObject, ObservableObject {
    struct SelectionItem: Identifiable, Equatable {
        let id: UUID
        let name: String
        let path: String
        let workspaceDescription: String
        let preferredRuntimeID: DelegationAgentRuntimeID?
    }

    struct RuntimeSelectionItem: Identifiable, Equatable {
        let id: DelegationAgentRuntimeID
        let displayName: String
        let shortLabel: String
        let launchDescription: String
    }

    struct DelegationSelection: Equatable {
        let workspace: SelectionItem
        let runtime: RuntimeSelectionItem
    }

    @Published private(set) var isVisible = false
    @Published private(set) var availableWorkspaces: [SelectionItem] = []
    @Published private(set) var availableRuntimes: [RuntimeSelectionItem] = []
    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var selectedRuntimeIndex: Int = 0
    @Published private(set) var headerTitleText: String = "Choose workspace"
    @Published private(set) var headerDetailText: String = "Choose a workspace and agent"

    private var overlayPanel: KeyablePickerPanel?
    private var cursorTrackingTimer: Timer?
    private var localKeyMonitor: Any?
    private var onSelectionConfirmed: ((DelegationSelection) -> Void)?
    private var onCancelled: (() -> Void)?

    private let cursorOffsetX: CGFloat = 20
    private let cursorOffsetY: CGFloat = 6
    private let overlayWidth: CGFloat = 320
    private let overlayMaxHeight: CGFloat = 260

    func show(
        workspaces: [WorkspaceInventoryStore.WorkspaceRecord],
        runtimes: [InstalledDelegationAgentRuntime],
        preselectedWorkspaceID: UUID? = nil,
        preselectedRuntimeID: DelegationAgentRuntimeID? = nil,
        title: String = "Choose workspace",
        detail: String = "Use arrow keys, return, or escape",
        onSelectionConfirmed: @escaping (DelegationSelection) -> Void,
        onCancelled: (() -> Void)? = nil
    ) {
        let selectionItems = workspaces.map {
            SelectionItem(
                id: $0.id,
                name: $0.name,
                path: $0.path,
                workspaceDescription: $0.workspaceDescription,
                preferredRuntimeID: $0.lastUsedDelegationRuntimeID
            )
        }
        let runtimeItems = runtimes.map {
            RuntimeSelectionItem(
                id: $0.runtimeID,
                displayName: $0.displayName,
                shortLabel: $0.shortLabel,
                launchDescription: $0.launchDescription
            )
        }

        guard !selectionItems.isEmpty, !runtimeItems.isEmpty else {
            hide()
            return
        }

        self.availableWorkspaces = selectionItems
        self.availableRuntimes = runtimeItems
        self.headerTitleText = title
        self.headerDetailText = detail
        self.onSelectionConfirmed = onSelectionConfirmed
        self.onCancelled = onCancelled
        self.selectedIndex = Self.initialSelectionIndex(
            for: selectionItems,
            preselectedWorkspaceID: preselectedWorkspaceID
        )
        self.selectedRuntimeIndex = Self.initialRuntimeSelectionIndex(
            for: runtimeItems,
            preselectedRuntimeID: preselectedRuntimeID ?? selectionItems[selectedIndex].preferredRuntimeID
        )

        isVisible = true
        createOverlayPanelIfNeeded()
        startCursorTracking()
        installLocalKeyMonitor()

        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
        overlayPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        repositionPanelNearCursor()
    }

    func hide() {
        isVisible = false
        stopCursorTracking()
        removeLocalKeyMonitor()
        overlayPanel?.orderOut(nil)
        onSelectionConfirmed = nil
        onCancelled = nil
    }

    func moveSelectionUp() {
        guard !availableWorkspaces.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        syncRuntimeSelectionWithSelectedWorkspace()
    }

    func moveSelectionDown() {
        guard !availableWorkspaces.isEmpty else { return }
        selectedIndex = min(availableWorkspaces.count - 1, selectedIndex + 1)
        syncRuntimeSelectionWithSelectedWorkspace()
    }

    func selectWorkspace(at index: Int) {
        guard availableWorkspaces.indices.contains(index) else { return }
        selectedIndex = index
        syncRuntimeSelectionWithSelectedWorkspace()
    }

    func moveRuntimeLeft() {
        guard !availableRuntimes.isEmpty else { return }
        selectedRuntimeIndex = max(0, selectedRuntimeIndex - 1)
    }

    func moveRuntimeRight() {
        guard !availableRuntimes.isEmpty else { return }
        selectedRuntimeIndex = min(availableRuntimes.count - 1, selectedRuntimeIndex + 1)
    }

    func selectRuntime(at index: Int) {
        guard availableRuntimes.indices.contains(index) else { return }
        selectedRuntimeIndex = index
    }

    func confirmSelection() {
        guard availableWorkspaces.indices.contains(selectedIndex),
              availableRuntimes.indices.contains(selectedRuntimeIndex) else { return }
        let selectedWorkspace = availableWorkspaces[selectedIndex]
        let selectedRuntime = availableRuntimes[selectedRuntimeIndex]
        let selectionHandler = onSelectionConfirmed
        hide()
        selectionHandler?(
            DelegationSelection(
                workspace: selectedWorkspace,
                runtime: selectedRuntime
            )
        )
    }

    func cancelSelection() {
        let cancellationHandler = onCancelled
        hide()
        cancellationHandler?()
    }

    private func installLocalKeyMonitor() {
        removeLocalKeyMonitor()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else {
                return event
            }

            switch event.keyCode {
            case 125:
                self.moveSelectionDown()
                return nil
            case 126:
                self.moveSelectionUp()
                return nil
            case 123:
                self.moveRuntimeLeft()
                return nil
            case 124:
                self.moveRuntimeRight()
                return nil
            case 36, 76:
                self.confirmSelection()
                return nil
            case 53:
                self.cancelSelection()
                return nil
            default:
                return event
            }
        }
    }

    private func removeLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayWidth, height: 180)
        let pickerPanel = KeyablePickerPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        pickerPanel.level = .statusBar
        pickerPanel.isOpaque = false
        pickerPanel.backgroundColor = .clear
        pickerPanel.hasShadow = false
        pickerPanel.hidesOnDeactivate = false
        pickerPanel.ignoresMouseEvents = false
        pickerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        pickerPanel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: DelegationRepoPickerOverlayView(viewModel: self)
        )
        hostingView.frame = initialFrame
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        pickerPanel.contentView = hostingView

        overlayPanel = pickerPanel
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
        let contentSize = overlayPanel.contentView?.fittingSize ?? overlayPanel.frame.size
        let panelWidth = overlayWidth
        let panelHeight = min(max(contentSize.height, 120), overlayMaxHeight)

        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelHeight

        if let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            let visibleFrame = currentScreen.visibleFrame

            if panelOriginX + panelWidth > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelWidth
            }

            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelWidth))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelHeight))
        }

        overlayPanel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    private static func initialSelectionIndex(
        for workspaces: [SelectionItem],
        preselectedWorkspaceID: UUID?
    ) -> Int {
        guard let preselectedWorkspaceID,
              let preselectedIndex = workspaces.firstIndex(where: { $0.id == preselectedWorkspaceID }) else {
            return 0
        }

        return preselectedIndex
    }

    private static func initialRuntimeSelectionIndex(
        for runtimes: [RuntimeSelectionItem],
        preselectedRuntimeID: DelegationAgentRuntimeID?
    ) -> Int {
        guard let preselectedRuntimeID,
              let preselectedIndex = runtimes.firstIndex(where: { $0.id == preselectedRuntimeID }) else {
            return 0
        }

        return preselectedIndex
    }

    private func syncRuntimeSelectionWithSelectedWorkspace() {
        guard availableWorkspaces.indices.contains(selectedIndex) else { return }

        selectedRuntimeIndex = Self.initialRuntimeSelectionIndex(
            for: availableRuntimes,
            preselectedRuntimeID: availableWorkspaces[selectedIndex].preferredRuntimeID
        )
    }
}

private final class KeyablePickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct DelegationRepoPickerOverlayView: View {
    @ObservedObject var viewModel: DelegationRepoPickerOverlayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            if viewModel.availableWorkspaces.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(viewModel.availableWorkspaces.enumerated()), id: \.element.id) { index, workspace in
                            SelectionRow(
                                workspace: workspace,
                                isSelected: index == viewModel.selectedIndex,
                                onSelect: {
                                    viewModel.selectWorkspace(at: index)
                                    viewModel.confirmSelection()
                                }
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 170)
            }

            if !viewModel.availableRuntimes.isEmpty {
                runtimeSection
            }

            footerSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
                )
        )
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.headerTitleText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(viewModel.headerDetailText)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var emptyState: some View {
        Text("No allowed workspaces yet.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    private var footerSection: some View {
        HStack {
            Text("↑ ↓ workspace  ← → agent  ↩ select")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            Text("\(viewModel.selectedIndex + 1)/\(max(viewModel.availableWorkspaces.count, 1)) · esc cancel")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: 6) {
                ForEach(Array(viewModel.availableRuntimes.enumerated()), id: \.element.id) { index, runtime in
                    RuntimeSelectionChip(
                        runtime: runtime,
                        isSelected: index == viewModel.selectedRuntimeIndex,
                        onSelect: {
                            viewModel.selectRuntime(at: index)
                        }
                    )
                }
            }

            if viewModel.availableRuntimes.indices.contains(viewModel.selectedRuntimeIndex) {
                Text(viewModel.availableRuntimes[viewModel.selectedRuntimeIndex].launchDescription)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SelectionRow: View {
    let workspace: DelegationRepoPickerOverlayManager.SelectionItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(workspace.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)

                        if isSelected {
                            Text("selected")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Colors.textOnAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(DS.Colors.accent)
                                )
                        }
                    }

                    Text(pathSummary)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)

                    if !workspace.workspaceDescription.isEmpty {
                        Text(workspace.workspaceDescription)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.55) : DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var pathSummary: String {
        let normalizedPath = workspace.path as NSString
        return normalizedPath.lastPathComponent.isEmpty ? workspace.path : normalizedPath.lastPathComponent
    }
}

private struct RuntimeSelectionChip: View {
    let runtime: DelegationRepoPickerOverlayManager.RuntimeSelectionItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(runtime.shortLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? DS.Colors.accent : Color.white.opacity(0.05))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? DS.Colors.accent.opacity(0.55) : DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
