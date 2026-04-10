//
//  DelegationLogSidebar.swift
//  leanring-buddy
//
//  Streams Codex delegation logs into a right-edge sidebar with a dramatic
//  dark-and-purple terminal aesthetic that matches Clicky's Headout theme.
//

import AppKit
import Combine
import Darwin
import SwiftUI

@MainActor
final class DelegationLogSidebarViewModel: ObservableObject {
    @Published var workspaceName: String = ""
    @Published var runtimeDisplayName: String = ""
    @Published var logFilePath: String = ""
    @Published var visibleLogLines: [String] = []
    @Published var statusText: String = "Waiting for logs..."
    @Published var latestLogActivityAt: Date = .distantPast
    @Published var baseBranchName: String = ""
    @Published var workingBranchName: String = ""
    @Published var isProcessComplete: Bool = false
    @Published var comparePullRequestURL: URL?

    var joinedLogText: String {
        visibleLogLines.joined(separator: "\n")
    }
}

@MainActor
final class DelegationLogSidebarManager {
    private let viewModel = DelegationLogSidebarViewModel()
    private var sidebarPanel: NSPanel?
    private var logPollingTimer: Timer?
    private var processMonitoringTimer: Timer?
    private var monitoredLogFileURL: URL?
    private var currentReadOffset: UInt64 = 0
    private var monitoredProcessIdentifier: Int32?

    private let sidebarWidth: CGFloat = 360
    private let sidebarHeight: CGFloat = 520
    private let maxVisibleLogLines = 320

    func showStreamingLogSidebar(
        logFileURL: URL,
        workspaceName: String,
        runtimeDisplayName: String,
        processIdentifier: Int32,
        baseBranchName: String,
        workingBranchName: String,
        comparePullRequestURL: URL?
    ) {
        monitoredLogFileURL = logFileURL
        monitoredProcessIdentifier = processIdentifier
        currentReadOffset = 0
        viewModel.workspaceName = workspaceName
        viewModel.runtimeDisplayName = runtimeDisplayName
        viewModel.logFilePath = logFileURL.path
        viewModel.baseBranchName = baseBranchName
        viewModel.workingBranchName = workingBranchName
        viewModel.comparePullRequestURL = comparePullRequestURL
        viewModel.isProcessComplete = false
        viewModel.visibleLogLines = [
            "flowee delegation boot sequence engaged",
            "workspace: \(workspaceName)",
            "agent: \(runtimeDisplayName)",
            "log file: \(logFileURL.lastPathComponent)",
            "branch: \(baseBranchName) -> \(workingBranchName)",
            ""
        ]
        viewModel.statusText = "Streaming live \(runtimeDisplayName) output"

        createSidebarPanelIfNeeded()
        positionSidebarOnRightEdge()
        sidebarPanel?.alphaValue = 1
        sidebarPanel?.orderFrontRegardless()
        startPollingLogFile()
        startMonitoringProcessLifecycle()
    }

    func hideStreamingLogSidebar() {
        stopPollingLogFile()
        stopMonitoringProcessLifecycle()
        monitoredLogFileURL = nil
        monitoredProcessIdentifier = nil
        currentReadOffset = 0
        sidebarPanel?.orderOut(nil)
    }

    private func createSidebarPanelIfNeeded() {
        if sidebarPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: sidebarWidth, height: sidebarHeight)
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: DelegationLogSidebarView(viewModel: viewModel)
        )
        hostingView.frame = initialFrame
        panel.contentView = hostingView

        sidebarPanel = panel
    }

    private func positionSidebarOnRightEdge() {
        guard let sidebarPanel else { return }

        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

        let panelOriginX = visibleFrame.maxX - sidebarWidth - 18
        let panelOriginY = visibleFrame.midY - (sidebarHeight / 2)

        sidebarPanel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: sidebarWidth, height: sidebarHeight),
            display: true
        )
    }

    private func startPollingLogFile() {
        stopPollingLogFile()
        logPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollLogFileForNewContent()
            }
        }
    }

    private func stopPollingLogFile() {
        logPollingTimer?.invalidate()
        logPollingTimer = nil
    }

    private func startMonitoringProcessLifecycle() {
        stopMonitoringProcessLifecycle()
        processMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollProcessLifecycle()
            }
        }
    }

    private func stopMonitoringProcessLifecycle() {
        processMonitoringTimer?.invalidate()
        processMonitoringTimer = nil
    }

    private func pollProcessLifecycle() {
        guard let monitoredProcessIdentifier, monitoredProcessIdentifier > 0 else { return }
        guard !viewModel.isProcessComplete else { return }

        let processStillRunning = kill(monitoredProcessIdentifier, 0) == 0
        if processStillRunning {
            return
        }

        viewModel.isProcessComplete = true
        viewModel.statusText = "Agent run complete. Raise a PR when you're ready."
        appendLogText(
            """

            flowee detected that the delegated agent finished.
            next move: raise a pr from \(viewModel.workingBranchName) into \(viewModel.baseBranchName)
            """
        )
        stopMonitoringProcessLifecycle()
    }

    private func pollLogFileForNewContent() {
        guard let monitoredLogFileURL else { return }

        do {
            let fileHandle = try FileHandle(forReadingFrom: monitoredLogFileURL)
            try fileHandle.seek(toOffset: currentReadOffset)
            let newData = fileHandle.readDataToEndOfFile()
            fileHandle.closeFile()

            guard !newData.isEmpty else { return }

            currentReadOffset += UInt64(newData.count)

            if let newText = String(data: newData, encoding: .utf8), !newText.isEmpty {
                appendLogText(newText)
            }
        } catch {
            viewModel.statusText = "Log stream interrupted"
        }
    }

    private func appendLogText(_ text: String) {
        let normalizedLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        for line in normalizedLines where !line.isEmpty {
            viewModel.visibleLogLines.append(line)
        }

        if viewModel.visibleLogLines.count > maxVisibleLogLines {
            viewModel.visibleLogLines.removeFirst(viewModel.visibleLogLines.count - maxVisibleLogLines)
        }

        viewModel.latestLogActivityAt = Date()
    }
}

private struct DelegationLogSidebarView: View {
    @ObservedObject var viewModel: DelegationLogSidebarViewModel
    @State private var scanSweepOffset: CGFloat = -420
    @State private var headerPulseOpacity: Double = 0.45
    @State private var logActivityIntensity: Double = 0.0

    var body: some View {
        ZStack {
            backgroundLayer
            scanlineLayer
            animatedSweepLayer

            VStack(alignment: .leading, spacing: 14) {
                headerSection
                logBodySection
                footerSection
                if viewModel.isProcessComplete {
                    completedPullRequestBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(DS.Colors.brandGradientStart.opacity(0.40), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 12)
        .shadow(color: DS.Colors.brandGradientEnd.opacity(0.14), radius: 16, x: 0, y: 0)
        .onAppear {
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                scanSweepOffset = 620
            }

            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                headerPulseOpacity = 0.90
            }
        }
        .onChange(of: viewModel.latestLogActivityAt) {
            triggerLogActivityPulse()
        }
    }

    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        DS.Colors.blue950.opacity(0.96),
                        Color(red: 0.09, green: 0.02, blue: 0.16),
                        Color.black.opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var scanlineLayer: some View {
        GeometryReader { geometry in
            let lineCount = Int(geometry.size.height / 4)
            VStack(spacing: 2) {
                ForEach(0..<lineCount, id: \.self) { _ in
                    Rectangle()
                        .fill(DS.Colors.brandGradientStart.opacity(0.028))
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var animatedSweepLayer: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            DS.Colors.brandGradientStart.opacity(0.0),
                            DS.Colors.brandGlow.opacity(0.10 + (logActivityIntensity * 0.20)),
                            DS.Colors.brandGradientEnd.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: geometry.size.width * 0.65, height: 90)
                .blur(radius: 18 - (logActivityIntensity * 4))
                .rotationEffect(.degrees(-9))
                .offset(x: scanSweepOffset, y: -geometry.size.height * 0.18)
                .opacity(0.55 + (logActivityIntensity * 0.35))
        }
        .allowsHitTesting(false)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(DS.Colors.brandGlow)
                    .frame(width: 8, height: 8)
                    .shadow(color: DS.Colors.brandGlow.opacity(headerPulseOpacity + (logActivityIntensity * 0.35)), radius: 10 + (logActivityIntensity * 6), x: 0, y: 0)
                    .opacity(min(headerPulseOpacity + (logActivityIntensity * 0.25), 1.0))

                Text("DELEGATION STREAM")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                DS.Colors.brandGradientStart,
                                DS.Colors.brandGlow
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: DS.Colors.brandGradientEnd.opacity(0.48), radius: 10, x: 0, y: 0)
            }

            Text(viewModel.workspaceName.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)

            Text(viewModel.statusText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.brandGradientStart)

            Text(viewModel.logFilePath)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
        }
    }

    private var logBodySection: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                Text(viewModel.joinedLogText.isEmpty ? "awaiting first output frame..." : viewModel.joinedLogText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(red: 0.90, green: 0.82, blue: 1.0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("delegation-log-bottom")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DS.Colors.brandGradientEnd.opacity(0.30), lineWidth: 0.8)
                    )
            )
            .onChange(of: viewModel.joinedLogText) {
                withAnimation(.easeOut(duration: 0.18)) {
                    scrollProxy.scrollTo("delegation-log-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Text("streaming live \(viewModel.runtimeDisplayName.lowercased()) output")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.brandGradientStart)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()

            Text("FLOWEE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(DS.Colors.brandGlow)
        }
    }

    private var completedPullRequestBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Raise a PR")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("\(viewModel.baseBranchName) ← \(viewModel.workingBranchName)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.brandGradientStart)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: {
                openPullRequestDestinationIfAvailable()
            }) {
                Text(viewModel.comparePullRequestURL == nil ? "Ready" : "Open PR")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        DS.Colors.brandGradientStart,
                                        DS.Colors.brandGradientEnd
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(viewModel.comparePullRequestURL == nil)
            .opacity(viewModel.comparePullRequestURL == nil ? 0.65 : 1.0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DS.Colors.brandGradientStart.opacity(0.32), lineWidth: 0.9)
                )
        )
    }

    private func triggerLogActivityPulse() {
        logActivityIntensity = 1.0

        withAnimation(.easeOut(duration: 0.9)) {
            logActivityIntensity = 0.0
        }

        scanSweepOffset = -420
        withAnimation(.linear(duration: 1.15)) {
            scanSweepOffset = 620
        }
    }

    private func openPullRequestDestinationIfAvailable() {
        guard let comparePullRequestURL = viewModel.comparePullRequestURL else { return }
        NSWorkspace.shared.open(comparePullRequestURL)
    }
}
